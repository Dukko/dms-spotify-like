import QtQuick
import qs.Common
import qs.Modules.Plugins
import qs.Widgets

PluginSettings {
    id: root
    pluginId: "spotifyLike"

    property bool connectedNow: false
    property string authStatus: ""

    function refreshConnectedState() {
        const rt = root.loadState("refreshToken", "");
        connectedNow = !!(rt && rt.length > 0);
    }

    function statusMessage() {
        if (authStatus === "connecting")
            return "Waiting for you to approve access in your browser...";
        if (authStatus === "success")
            return "Connected to Spotify.";
        if (authStatus.startsWith("error:")) {
            const code = authStatus.substring(6);
            if (code === "missing_client_id")
                return "Enter a Client ID first.";
            if (code === "timeout")
                return "Timed out waiting for authorization. Try again.";
            if (code === "port_in_use")
                return "Redirect port is already in use. Pick a different port.";
            if (code === "access_denied")
                return "Authorization was denied.";
            return "Connection failed (" + code + "). Check the Client ID and redirect URI.";
        }
        return "";
    }

    function startConnect() {
        const clientId = (root.loadValue("clientId", "") || "").trim();
        const port = (root.loadValue("redirectPort", "8899") || "8899").toString().trim();
        if (!clientId) {
            authStatus = "error:missing_client_id";
            return;
        }
        if (!root.pluginService) {
            authStatus = "error:no_plugin_service";
            return;
        }
        const scriptPath = root.pluginService.getPluginPath(root.pluginId) + "/spotify_auth.py";
        authStatus = "connecting";
        Proc.runCommand("spotifyLike-connect", ["python3", scriptPath, clientId, port], (output, exitCode) => {
            let data = null;
            const raw = (output || "").trim();
            try {
                data = JSON.parse(raw);
            } catch (e) {
                // Some browser launchers print stray status text to stdout
                // ahead of our JSON; fall back to the last {...} object.
                const lastBrace = raw.lastIndexOf("{");
                if (lastBrace >= 0) {
                    try {
                        data = JSON.parse(raw.substring(lastBrace));
                    } catch (e2) {
                        data = null;
                    }
                }
            }
            if (exitCode === 0 && data && data.access_token) {
                root.saveState("accessToken", data.access_token);
                root.saveState("refreshToken", data.refresh_token || "");
                root.saveState("tokenExpiresAt", Date.now() + (data.expires_in || 3600) * 1000);
                root.saveState("grantedScope", data.scope || "");
                authStatus = "success";
            } else {
                authStatus = "error:" + ((data && data.error) || "unknown");
            }
            root.refreshConnectedState();
        }, 0, 130000);
    }

    function disconnect() {
        root.clearState();
        authStatus = "";
        root.refreshConnectedState();
    }

    Component.onCompleted: {
        refreshConnectedState();
        // DMS's very first pluginState write for a given plugin id can silently
        // fail on disk (a FileView.loaded/.loadFailed signal-connect quirk in
        // PluginService) while still updating the in-memory cache. Do a
        // harmless dummy write now, well before Connect could finish, so the
        // real token write later lands on the already-initialized (working)
        // write path instead of hitting that first-write bug.
        root.saveState("_primed", true);
    }

    Connections {
        target: root.pluginService
        function onPluginStateChanged(changedPluginId) {
            if (changedPluginId === root.pluginId)
                root.refreshConnectedState();
        }
    }

    StyledText {
        width: parent.width
        text: "Spotify Like"
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
    }

    StyledText {
        width: parent.width
        text: "A DankDash-style media popout with a heart button that saves or removes the current track from your Spotify Library. Requires a free Spotify Developer app (no client secret needed)."
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }

    StyledRect {
        width: parent.width
        height: setupColumn.implicitHeight + Theme.spacingL * 2
        radius: Theme.cornerRadius
        color: Theme.surfaceContainerHigh

        Column {
            id: setupColumn
            anchors.fill: parent
            anchors.margins: Theme.spacingL
            spacing: Theme.spacingM

            StyledText {
                text: "One-time setup"
                font.pixelSize: Theme.fontSizeMedium
                font.weight: Font.Medium
                color: Theme.surfaceText
            }

            StyledText {
                width: parent.width
                wrapMode: Text.WordWrap
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
                text: "1. Go to developer.spotify.com/dashboard and create an app (any name/description).\n2. In the app's settings, set a Redirect URI to http://127.0.0.1:" + (root.loadValue("redirectPort", "8899") || "8899") + "/callback and save.\n3. Copy the app's Client ID and paste it below.\n4. Click Connect to Spotify and approve access in your browser."
            }

            StringSetting {
                settingKey: "clientId"
                label: "Spotify Client ID"
                description: "From your app's page at developer.spotify.com/dashboard"
                placeholder: "e.g. 5f8b2b1a9c3f4e0e9c8a1b2c3d4e5f60"
                defaultValue: ""
            }

            StringSetting {
                settingKey: "redirectPort"
                label: "Redirect Port"
                description: "Must match the port in the Redirect URI you added to the Spotify app"
                placeholder: "8899"
                defaultValue: "8899"
            }

            Rectangle {
                width: parent.width
                height: 1
                color: Theme.outline
                opacity: 0.3
            }

            Row {
                spacing: Theme.spacingM

                Rectangle {
                    width: connectLabel.implicitWidth + Theme.spacingL * 2
                    height: 40
                    radius: Theme.cornerRadius
                    color: root.connectedNow ? Theme.surfaceContainerHighest : Theme.primary
                    border.width: root.connectedNow ? 1 : 0
                    border.color: Theme.outline

                    StyledText {
                        id: connectLabel
                        anchors.centerIn: parent
                        text: root.connectedNow ? "Disconnect" : (root.authStatus === "connecting" ? "Waiting..." : "Connect to Spotify")
                        font.pixelSize: Theme.fontSizeMedium
                        font.weight: Font.Medium
                        color: root.connectedNow ? Theme.surfaceText : Theme.background
                    }

                    MouseArea {
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        enabled: root.authStatus !== "connecting"
                        onClicked: root.connectedNow ? root.disconnect() : root.startConnect()
                    }
                }

                DankIcon {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: root.connectedNow
                    name: "check_circle"
                    size: 20
                    color: Theme.primary
                }

                StyledText {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: root.connectedNow
                    text: "Connected"
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.primary
                }
            }

            StyledText {
                width: parent.width
                visible: root.statusMessage().length > 0
                text: root.statusMessage()
                font.pixelSize: Theme.fontSizeSmall
                color: root.authStatus.startsWith("error:") ? Theme.error : Theme.surfaceVariantText
                wrapMode: Text.WordWrap
            }
        }
    }

    StyledText {
        width: parent.width
        text: "The heart button in the popout only works for tracks playing through the official Spotify client, since it needs a real Spotify track ID."
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }
}
