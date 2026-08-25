import QtQuick
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

    // Runs a Spotify Web API call and splits curl's trailing %{http_code} off
    // the body, since --fail discards the response body we'd otherwise want
    // to diagnose failures with (e.g. distinguishing 401 vs 403 vs network).
    function runSpotifyApi(id, args, callback) {
        const fullArgs = ["curl", "-sS", "--connect-timeout", "5", "--max-time", "8", "-w", "\n%{http_code}"].concat(args);
        Proc.runCommand(id, fullArgs, (output, exitCode) => {
            const text = output || "";
            const idx = text.lastIndexOf("\n");
            const status = idx >= 0 ? text.substring(idx + 1).trim() : "";
            const body = idx >= 0 ? text.substring(0, idx) : text;
            const ok = exitCode === 0 && status.length === 3 && status[0] === "2";
            callback(ok, body, status);
        }, 0, 10000);
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

    function persistTokens() {
        if (!root.pluginService || !root.pluginId)
            return;
        root.pluginService.savePluginState(root.pluginId, "accessToken", accessToken);
        root.pluginService.savePluginState(root.pluginId, "refreshToken", refreshToken);
        root.pluginService.savePluginState(root.pluginId, "tokenExpiresAt", tokenExpiresAt);
    }

    function ensureValidToken(callback) {
        if (!refreshToken) {
            callback(false);
            return;
        }
        if (accessToken && Date.now() < tokenExpiresAt - 30000) {
            callback(true);
            return;
        }
        doRefresh(callback);
    }

    function doRefresh(callback) {
        if (!clientId || !refreshToken) {
            callback(false);
            return;
        }
        const args = ["curl", "-sS", "--fail", "--connect-timeout", "5", "--max-time", "10", "-X", "POST", "-d", "grant_type=refresh_token", "-d", "refresh_token=" + refreshToken, "-d", "client_id=" + clientId, "https://accounts.spotify.com/api/token"];
        Proc.runCommand("spotifyLike-refresh", args, (output, exitCode) => {
            if (exitCode !== 0) {
                callback(false);
                return;
            }
            try {
                const data = JSON.parse(output);
                if (!data.access_token) {
                    callback(false);
                    return;
                }
                accessToken = data.access_token;
                tokenExpiresAt = Date.now() + (data.expires_in || 3600) * 1000;
                if (data.refresh_token)
                    refreshToken = data.refresh_token;
                persistTokens();
                callback(true);
            } catch (e) {
                callback(false);
            }
        }, 0, 15000);
    }

    function checkSaved() {
        const id = currentTrackId;
        if (!id || !connected) {
            isSavedCurrent = false;
            return;
        }
        ensureValidToken(ok => {
            if (!ok || root.currentTrackId !== id)
                return;
            runSpotifyApi("spotifyLike-check", ["-H", "Authorization: Bearer " + accessToken, "https://api.spotify.com/v1/me/library/contains?uris=spotify:track:" + id], (ok2, body, status) => {
                if (root.currentTrackId !== id)
                    return;
                if (!ok2) {
                    lastApiError = describeHttpError(status);
                    return;
                }
                lastApiError = "";
                try {
                    const arr = JSON.parse(body);
                    isSavedCurrent = !!arr[0];
                } catch (e) {}
            });
        });
    }

    function toggleSaved() {
        const id = currentTrackId;
        if (!id || !connected || savePending)
            return;
        const wasSaved = isSavedCurrent;
        savePending = true;
        ensureValidToken(ok => {
            if (!ok) {
                savePending = false;
                lastApiError = describeHttpError("");
                return;
            }
            const method = wasSaved ? "DELETE" : "PUT";
            runSpotifyApi("spotifyLike-toggle", ["-X", method, "-H", "Authorization: Bearer " + accessToken, "https://api.spotify.com/v1/me/library?uris=spotify:track:" + id], (ok2, body, status) => {
                savePending = false;
                if (!ok2) {
                    lastApiError = describeHttpError(status);
                    return;
                }
                lastApiError = "";
                if (root.currentTrackId === id)
                    isSavedCurrent = !wasSaved;
            });
        });
    }

    onCurrentTrackIdChanged: checkSaved()
    onConnectedChanged: checkSaved()

    Connections {
        target: root.pluginService
        function onPluginStateChanged(changedPluginId) {
            if (changedPluginId === root.pluginId) {
                root.loadTokens();
                root.checkSaved();
            }
        }
    }

    // pluginService/pluginId are injected by the loader after this component is
    // constructed, so Component.onCompleted can fire before they're set. Re-load
    // whenever they become available so we don't get stuck with empty tokens.
    Connections {
        target: root
        function onPluginServiceChanged() {
            root.loadTokens();
            root.checkSaved();
        }
        function onPluginIdChanged() {
            root.loadTokens();
            root.checkSaved();
        }
    }

    Component.onCompleted: {
        loadTokens();
        checkSaved();
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
