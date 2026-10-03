import QtQuick
import Quickshell.Io
import Quickshell.Services.Mpris
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins

PluginComponent {
    id: root

    layerNamespacePlugin: "spotify-like"

    popoutWidth: 460
    popoutHeight: 460

    pillRightClickAction: () => PopoutService.openSettingsWithTab("plugins")

    readonly property MprisPlayer activePlayer: MprisController.activePlayer
    readonly property bool playerAvailable: !!(activePlayer && (((activePlayer.trackTitle || "").length > 0) || ((activePlayer.trackArtist || "").length > 0)))
    readonly property bool isSpotifyPlayer: !!(activePlayer && (activePlayer.identity || "").toLowerCase().includes("spotify"))
    readonly property string currentTrackId: extractSpotifyTrackId(activePlayer)

    readonly property int textPixelSize: Theme.barTextSize(root.barThickness, root.barConfig?.fontScale, root.barConfig?.maximizeWidgetText)

    property string clientId: pluginData.clientId || ""
    property int redirectPort: pluginData.redirectPort ? parseInt(pluginData.redirectPort) : 8899

    property string accessToken: ""
    property string refreshToken: ""
    property double tokenExpiresAt: 0
    readonly property bool connected: refreshToken.length > 0

    property bool isSavedCurrent: false
    property bool savePending: false
    property string lastApiError: ""

    // ------------------------------------------------------------------
    // Request accounting.
    //
    // Spotify bills every /v1/me/library call against a hard per-app rate
    // limit, and accounts.spotify.com/api/token tighter still. The state
    // below exists so a track change costs exactly one library check, a token
    // expiry costs exactly one refresh, and a popout opening costs nothing at
    // all because the answer for the current track is already cached.
    // ------------------------------------------------------------------
    property bool _writingOwnState: false  // set while persisting our own tokens
    property bool _refreshInFlight: false
    property var _refreshWaiters: []        // callbacks sharing that one refresh
    property bool _checkInFlight: false
    property string _queuedTrackId: ""      // newest track we still owe an answer
    property int _answerSeq: 0             // supersedes responses about old tracks
    property string _answeredTrackId: ""    // the one track we hold an answer for
    property bool _authRejected: false      // Spotify refused the token; stop trying

    readonly property string apiScriptPath: (root.pluginService ? root.pluginService.getPluginPath(root.pluginId) : "") + "/spotify_api.py"

    function describeHttpError(status) {
        if (status === "401")
            return "Spotify rejected the token (401). Try reconnecting in plugin settings.";
        if (status === "403")
            return "Spotify blocked this (403). In your app's dashboard, add your account under Settings → Users and Access.";
        if (status === "429")
            return "Rate limited by Spotify (429). Try again in a moment.";
        if (status)
            return "Spotify API error (" + status + ").";
        return "Couldn't reach Spotify. Check your network connection.";
    }

    // Runs one Spotify operation through spotify_api.py. The bearer token goes
    // to the helper's stdin and never into its argv, because argv is
    // world-readable through /proc/<pid>/cmdline while it runs. The request is
    // one line of JSON, so the helper never has to wait for stdin to close.
    //
    // The callback is (ok, body, status): status is the HTTP code when Spotify
    // answered and "" when the request never got that far.
    function runSpotifyApi(op, payload, callback) {
        if (!root.pluginService || !root.pluginId)
            return;
        const proc = apiProc.createObject(root, {
            command: ["python3", root.apiScriptPath],
            requestLine: JSON.stringify(Object.assign({ op: op }, payload)),
            cb: callback
        });
        if (proc)
            proc.running = true;
    }

    Component {
        id: apiProc

        Process {
            id: proc

            property string requestLine: ""
            property var cb: null
            property string capturedOut: ""
            property bool settled: false

            running: false
            stdinEnabled: true
            stdout: StdioCollector {
                onStreamFinished: proc.capturedOut = text || ""
            }
            stderr: StdioCollector {}

            onStarted: proc.write(proc.requestLine + "\n")

            // Quickshell emits exited() before runningChanged() on a normal
            // exit, but emits only runningChanged() when the process never
            // starts at all (no python3 on PATH). Settling from both, exactly
            // once, means a callback is always delivered -- otherwise a missing
            // interpreter would latch _refreshInFlight/_checkInFlight forever and
            // silently freeze the heart button.
            onRunningChanged: {
                if (!proc.running)
                    proc.settle(-1, "");
            }
            onExited: (exitCode, exitStatus) => proc.settle(exitCode, proc.capturedOut)

            // cb(ok, body, status): status is the HTTP code when Spotify
            // answered, "" when the request never got that far.
            function settle(exitCode, raw) {
                if (settled)
                    return;
                settled = true;
                const callback = proc.cb;
                const out = (raw || "").trim();
                Qt.callLater(() => proc.destroy());
                if (!callback)
                    return;
                let result = null;
                try {
                    result = JSON.parse(out);
                } catch (e) {
                    result = null;
                }
                if (!result || typeof result !== "object") {
                    callback(false, "", "");
                    return;
                }
                callback(!!result.ok, result.body || "", result.status ? String(result.status) : "");
            }
        }
    }

    // Coalesces the bursts of triggers that all want the same answer (a track
    // change, a state write from Settings, the popout opening) into one request.
    Timer {
        id: checkDebounce
        interval: 300
        repeat: false
        onTriggered: root.runCheck()
    }

    function extractSpotifyTrackId(player) {
        if (!player)
            return "";
        const tid = String(player.metadata?.["mpris:trackid"] || "");
        let m = tid.match(/track[\/:]([A-Za-z0-9]+)/);
        if (m)
            return m[1];
        const url = String(player.metadata?.["xesam:url"] || "");
        m = url.match(/open\.spotify\.com\/track\/([A-Za-z0-9]+)/);
        if (m)
            return m[1];
        return "";
    }

    function loadTokens() {
        if (!root.pluginService || !root.pluginId)
            return;
        accessToken = root.pluginService.loadPluginState(root.pluginId, "accessToken", "") || "";
        refreshToken = root.pluginService.loadPluginState(root.pluginId, "refreshToken", "") || "";
        tokenExpiresAt = root.pluginService.loadPluginState(root.pluginId, "tokenExpiresAt", 0) || 0;
    }

    // Persisting tokens fires pluginStateChanged once per key, and our own
    // handler reacts to that signal by reloading tokens and re-checking the
    // library. Re-entering that handler between the three writes is what used
    // to turn one token expiry into an unbounded burst of refresh requests:
    // the re-entrant reload restored the still-expired tokenExpiresAt that the
    // third write was about to replace, so the expiry never actually took,
    // every re-entry started another refresh, and every refresh wrote state
    // again. Suppressing our own reactions for the duration of the write makes
    // all three writes invisible to the handler.
    function persistTokens() {
        if (!root.pluginService || !root.pluginId)
            return;
        root._writingOwnState = true;
        try {
            root.pluginService.savePluginState(root.pluginId, "accessToken", accessToken);
            root.pluginService.savePluginState(root.pluginId, "refreshToken", refreshToken);
            root.pluginService.savePluginState(root.pluginId, "tokenExpiresAt", tokenExpiresAt);
        } finally {
            root._writingOwnState = false;
        }
    }

    // One refresh serves every caller. Giving each waiter its own request would
    // spend the token endpoint's budget to learn the same thing repeatedly.
    function ensureValidToken(callback) {
        if (!refreshToken) {
            callback(false);
            return;
        }
        if (accessToken && Date.now() < tokenExpiresAt - 60000) {
            callback(true);
            return;
        }
        if (!clientId) {
            // Nothing to refresh against. Failing here rather than letting the
            // helper reject it keeps a pointless process off the track-change
            // path.
            callback(false);
            return;
        }
        if (_refreshInFlight) {
            _refreshWaiters.push(callback);
            return;
        }
        _refreshInFlight = true;
        _refreshWaiters = [callback];
        runSpotifyApi("refresh", { client_id: clientId, refresh_token: refreshToken }, (ok, body, status) => {
            const waiters = root._refreshWaiters;
            root._refreshWaiters = [];
            root._refreshInFlight = false;
            const settle = granted => {
                for (let i = 0; i < waiters.length; i++)
                    waiters[i](granted);
            };
            if (!ok) {
                // A rejected grant means the refresh token is spent; retrying it
                // on every track change would burn the limit for nothing.
                if (status === "400" || status === "401")
                    root._authRejected = true;
                settle(false);
                return;
            }
            let data = null;
            try {
                data = JSON.parse(body);
            } catch (e) {
                data = null;
            }
            if (!data || !data.access_token) {
                settle(false);
                return;
            }
            root.accessToken = data.access_token;
            root.tokenExpiresAt = Date.now() + (data.expires_in || 3600) * 1000;
            if (data.refresh_token)
                root.refreshToken = data.refresh_token;
            root.persistTokens();
            settle(true);
        });
    }

    // Every reason to want a library answer funnels through here. It skips
    // tracks we have already answered and collapses bursts into one request,
    // so opening the popout or a Settings write costs nothing once the current
    // track is known.
    function requestCheck() {
        if (!connected || currentTrackId.length === 0 || _authRejected) {
            _queuedTrackId = "";
            return;
        }
        if (_answeredTrackId === currentTrackId && lastApiError === "")
            return;
        checkDebounce.restart();
    }

    function runCheck() {
        const id = currentTrackId;
        if (!id || !connected || _authRejected)
            return;
        if (_answeredTrackId === id && lastApiError === "")
            return;
        if (_checkInFlight) {
            // One check at a time; remember the newest track so the in-flight
            // completion can come back for it.
            _queuedTrackId = id;
            return;
        }
        // _answerSeq invalidates any older response still in flight.
        const seq = ++_answerSeq;
        _checkInFlight = true;
        _queuedTrackId = "";
        ensureValidToken(ok => {
            if (!ok) {
                root._checkInFlight = false;
                if (seq === root._answerSeq)
                    root.lastApiError = root.describeHttpError("");
                root.serviceQueuedCheck();
                return;
            }
            root.runSpotifyApi("contains", { token: root.accessToken, track_id: id }, (ok2, body, status) => {
                root._checkInFlight = false;
                if (seq === root._answerSeq && root.currentTrackId === id) {
                    if (!ok2) {
                        if (status === "401")
                            root._authRejected = true;
                        root.lastApiError = root.describeHttpError(status);
                    } else {
                        root.lastApiError = "";
                        try {
                            root._answeredTrackId = id;
                            root.isSavedCurrent = !!JSON.parse(body)[0];
                        } catch (e) {}
                    }
                }
                root.serviceQueuedCheck();
            });
        });
    }

    // If a newer track was queued while a check was in flight, answer it now.
    // Runs from the completion handler either way, so a superseded check still
    // hands over cleanly instead of stranding the queued track.
    function serviceQueuedCheck() {
        if (_queuedTrackId && _queuedTrackId !== _answeredTrackId)
            runCheck();
    }

    function toggleSaved() {
        const id = currentTrackId;
        if (!id || !connected || savePending || _authRejected)
            return;
        const wasSaved = isSavedCurrent;
        savePending = true;
        // A toggle is the new truth, so bump the sequence to make any check
        // still in flight stale: it must not come back and overwrite the answer
        // we are about to set with the pre-toggle value.
        _answerSeq++;
        ensureValidToken(ok => {
            if (!ok) {
                root.savePending = false;
                root.lastApiError = root.describeHttpError("");
                return;
            }
            root.runSpotifyApi(wasSaved ? "remove" : "save", { token: root.accessToken, track_id: id }, (ok2, body, status) => {
                root.savePending = false;
                if (!ok2) {
                    if (status === "401")
                        root._authRejected = true;
                    root.lastApiError = root.describeHttpError(status);
                    // The library state is unknown again; the next track change
                    // re-checks. No immediate retry, so a 429 costs one call
                    // rather than another one straight away.
                    root._answeredTrackId = "";
                    return;
                }
                root.lastApiError = "";
                if (root.currentTrackId === id) {
                    root._answeredTrackId = id;
                    root.isSavedCurrent = !wasSaved;
                }
            });
        });
    }

    function resetSavedState() {
        isSavedCurrent = false;
        lastApiError = "";
        _answeredTrackId = "";
        _queuedTrackId = "";
        _authRejected = false;
        _answerSeq++;
        checkDebounce.stop();
    }

    onCurrentTrackIdChanged: {
        if (_answeredTrackId !== currentTrackId)
            lastApiError = "";
        requestCheck();
    }
    onConnectedChanged: {
        if (!connected)
            resetSavedState();
        else
            _authRejected = false;
        requestCheck();
    }

    Connections {
        target: root.pluginService
        function onPluginStateChanged(changedPluginId) {
            // Our own token writes are suppressed here; anything else means
            // another surface (Settings) changed our state, so re-read it and
            // ask for a check. Re-reading tokens flips `connected` when the
            // account is connected or disconnected, which onConnectedChanged
            // already handles.
            if (changedPluginId !== root.pluginId || root._writingOwnState)
                return;
            root.loadTokens();
            root.requestCheck();
        }
    }

    // pluginService/pluginId are injected by the loader after this component is
    // constructed, so Component.onCompleted can fire before they're set. Re-load
    // whenever they become available so we don't get stuck with empty tokens.
    Connections {
        target: root
        function onPluginServiceChanged() {
            root.loadTokens();
            root.requestCheck();
        }
        function onPluginIdChanged() {
            root.loadTokens();
            root.requestCheck();
        }
    }

    Component.onCompleted: {
        loadTokens();
        requestCheck();
    }

    function pillText() {
        if (!playerAvailable)
            return "";
        const title = activePlayer.trackTitle || "";
        const artist = activePlayer.trackArtist || "";
        if (title.length === 0 && artist.length === 0)
            return activePlayer.identity || "Media";
        return artist.length > 0 ? title + " • " + artist : title;
    }

    horizontalBarPill: Component {
        Row {
            spacing: Theme.spacingXS

            DankIcon {
                anchors.verticalCenter: parent.verticalCenter
                name: root.isSavedCurrent ? "favorite" : "music_note"
                size: root.iconSize
                color: root.isSavedCurrent ? Theme.primary : Theme.widgetTextColor
            }

            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                visible: root.playerAvailable
                text: root.pillText()
                font.pixelSize: root.textPixelSize
                color: Theme.widgetTextColor
                wrapMode: Text.NoWrap
                elide: Text.ElideRight
                width: Math.min(220, implicitWidth)
            }
        }
    }

    verticalBarPill: Component {
        Column {
            spacing: Theme.spacingXS

            DankIcon {
                anchors.horizontalCenter: parent.horizontalCenter
                name: root.isSavedCurrent ? "favorite" : "music_note"
                size: root.iconSize
                color: root.isSavedCurrent ? Theme.primary : Theme.widgetTextColor
            }
        }
    }

    popoutContent: Component {
        SpotifyLikePopout {
            widgetRoot: root
        }
    }
}