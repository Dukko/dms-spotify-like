import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import QtQuick.Layouts
import Quickshell.Services.Mpris
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins

PopoutComponent {
    id: root

    property var widgetRoot: null

    headerText: "Spotify"
    showCloseButton: true

    readonly property MprisPlayer activePlayer: MprisController.activePlayer
    readonly property real stableLength: MprisController.activePlayerStableLength
    readonly property var allPlayers: MprisController.availablePlayers
    readonly property bool noneAvailable: (allPlayers ? allPlayers.length : 0) === 0
    readonly property bool trulyIdle: activePlayer && activePlayer.playbackState === MprisPlaybackState.Stopped && !activePlayer.trackTitle && !activePlayer.trackArtist
    readonly property bool showNoPlayerNow: noneAvailable || trulyIdle || !activePlayer

    readonly property bool isChromePlayer: {
        if (!activePlayer?.identity)
            return false;
        const id = activePlayer.identity.toLowerCase();
        return id.includes("chrome") || id.includes("chromium");
    }
    readonly property bool usePlayerVolume: activePlayer && activePlayer.volumeSupported && !isChromePlayer
    readonly property bool volumeAvailable: !!((activePlayer && activePlayer.volumeSupported && !isChromePlayer) || (AudioService.sink && AudioService.sink.audio))
    readonly property real currentVolume: usePlayerVolume ? activePlayer.volume : (AudioService.sink?.audio?.volume ?? 0)
    property real previousVolume: 0.0
    property bool isSeeking: false
    readonly property var availableDevices: AudioService.getAvailableSinks()

    // Flyouts use QtQuick.Controls Popup parented to the overlay of this
    // popout's own window -- the same mechanism DankDropdown and every
    // context menu in this shell use. On Wayland this renders as a real
    // xdg-popup subsurface, so it can extend past this card's edges without
    // being clipped to it, and (unlike a second independent DankPopout
    // window) it doesn't fight this popout's own focus-grab/dismiss logic.
    function openFlyout(popout, anchorItem) {
        if (!anchorItem)
            return;
        const overlay = root.Overlay.overlay;
        if (!overlay)
            return;
        const cardRight = contentCard.mapToItem(overlay, contentCard.width, 0);
        const buttonTop = anchorItem.mapToItem(overlay, 0, 0);
        popout.x = cardRight.x + Theme.spacingS;
        popout.y = buttonTop.y;
        popout.open();
    }

    function closeFlyouts() {
        volumeFlyout.close();
        deviceFlyout.close();
    }

    function setVolume(volume) {
        if (!volumeAvailable)
            return;
        const clamped = Math.max(0, Math.min(1, volume));
        SessionData.suppressOSDTemporarily();
        if (usePlayerVolume) {
            activePlayer.volume = clamped;
        } else if (AudioService.sink?.audio) {
            AudioService.sink.audio.muted = false;
            AudioService.sink.audio.volume = clamped;
        }
    }

    readonly property bool heartEnabled: !!(widgetRoot && widgetRoot.connected && widgetRoot.isSpotifyPlayer && widgetRoot.currentTrackId.length > 0 && !widgetRoot.savePending)
    readonly property string heartTooltip: {
        if (!widgetRoot || !widgetRoot.connected)
            return "Connect Spotify in plugin settings";
        if (!widgetRoot.isSpotifyPlayer)
            return "Only available for Spotify tracks";
        if (widgetRoot.lastApiError)
            return widgetRoot.lastApiError;
        return widgetRoot.isSavedCurrent ? "Remove from Library" : "Save to Library";
    }

    function getVolumeIcon() {
        if (!volumeAvailable)
            return "volume_off";
        if (usePlayerVolume)
            return currentVolume === 0.0 ? "music_off" : "music_note";
        if (currentVolume === 0.0)
            return "volume_off";
        if (currentVolume <= 0.33)
            return "volume_down";
        return "volume_up";
    }

    function toggleMute() {
        if (!volumeAvailable)
            return;
        SessionData.suppressOSDTemporarily();
        if (currentVolume > 0) {
            previousVolume = currentVolume;
            if (usePlayerVolume)
                activePlayer.volume = 0;
            else if (AudioService.sink?.audio)
                AudioService.sink.audio.muted = true;
        } else {
            const restore = previousVolume > 0 ? previousVolume : 0.5;
            if (usePlayerVolume) {
                activePlayer.volume = restore;
            } else if (AudioService.sink?.audio) {
                AudioService.sink.audio.muted = false;
                AudioService.sink.audio.volume = restore;
            }
        }
    }

    function adjustVolume(step) {
        if (!volumeAvailable)
            return;
        SessionData.suppressOSDTemporarily();
        const maxVol = usePlayerVolume ? 100 : AudioService.sinkMaxVolume;
        const current = Math.round(currentVolume * 100);
        const newVolume = Math.min(maxVol, Math.max(0, current + step));
        if (usePlayerVolume) {
            activePlayer.volume = newVolume / 100;
        } else if (AudioService.sink?.audio) {
            AudioService.sink.audio.volume = newVolume / 100;
        }
    }

    function getAudioDeviceIcon(device) {
        if (!device?.name)
            return "speaker";
        const name = device.name.toLowerCase();
        if (name.includes("bluez") || name.includes("bluetooth"))
            return "headset";
        if (name.includes("hdmi"))
            return "tv";
        if (name.includes("usb"))
            return "headset";
        return "speaker";
    }

    // Re-read saved tokens when the popout opens, so a Connect done in Settings
    // is picked up even if the live-update signal was missed (e.g. the widget
    // instance was created before pluginService was ready). This only re-reads
    // local state; requestCheck() is a no-op once the current track's library
    // answer is already known, so opening the popout costs no API call.
    Component.onCompleted: {
        if (root.widgetRoot) {
            root.widgetRoot.loadTokens();
            root.widgetRoot.requestCheck();
        }
    }

    DankTooltipV2 {
        id: sharedTooltip
    }

    Popup {
        id: volumeFlyout
        parent: root.Overlay.overlay
        width: 64
        height: 180
        padding: 0
        modal: true
        dim: false
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

        background: Rectangle {
            color: "transparent"
        }

        contentItem: Rectangle {
            radius: Theme.cornerRadius * 2
            color: Theme.withAlpha(Theme.surfaceContainer, 0.98)
            border.color: Theme.withAlpha(Theme.outline, 0.6)
            border.width: 2

            ElevationShadow {
                anchors.fill: parent
                z: -1
                level: Theme.elevationLevel2
                fallbackOffset: 4
                targetRadius: parent.radius
                targetColor: parent.color
                borderColor: parent.border.color
                borderWidth: parent.border.width
                shadowEnabled: Theme.elevationEnabled
            }

            Item {
                    anchors.fill: parent
                    anchors.margins: Theme.spacingS

                    Item {
                        id: fillTrack
                        width: parent.width * 0.5
                        height: parent.height - Theme.spacingXL * 2
                        anchors.top: parent.top
                        anchors.topMargin: Theme.spacingS
                        anchors.horizontalCenter: parent.horizontalCenter

                        Rectangle {
                            anchors.fill: parent
                            color: Theme.withAlpha(Theme.surfaceContainerHigh, Theme.popupTransparency)
                            radius: Theme.cornerRadius
                        }

                        Rectangle {
                            width: parent.width
                            height: root.volumeAvailable ? (Math.min(1.0, root.currentVolume) * parent.height) : 0
                            anchors.bottom: parent.bottom
                            anchors.horizontalCenter: parent.horizontalCenter
                            color: Theme.primary
                            bottomLeftRadius: Theme.cornerRadius
                            bottomRightRadius: Theme.cornerRadius
                        }

                        Rectangle {
                            width: parent.width + 8
                            height: 8
                            radius: Theme.cornerRadius
                            y: {
                                const ratio = root.volumeAvailable ? Math.min(1.0, root.currentVolume) : 0;
                                const travel = parent.height - height;
                                return Math.max(0, Math.min(travel, travel * (1 - ratio)));
                            }
                            anchors.horizontalCenter: parent.horizontalCenter
                            color: Theme.primary
                            border.width: 3
                            border.color: Theme.surfaceContainer
                        }

                        MouseArea {
                            anchors.fill: parent
                            anchors.margins: -12
                            enabled: root.volumeAvailable
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            preventStealing: true
                            onPressed: mouse => updateVolume(mouse)
                            onPositionChanged: mouse => {
                                if (pressed)
                                    updateVolume(mouse);
                            }
                            onClicked: mouse => updateVolume(mouse)

                            function updateVolume(mouse) {
                                if (!root.volumeAvailable)
                                    return;
                                root.setVolume(1.0 - (mouse.y / fillTrack.height));
                            }
                        }
                    }

                    StyledText {
                        anchors.bottom: parent.bottom
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.bottomMargin: Theme.spacingM
                        text: root.volumeAvailable ? Math.round(root.currentVolume * 100) + "%" : "0%"
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceText
                        font.weight: Font.Medium
                    }
                }
            }
        }
    Popup {
        id: deviceFlyout
        parent: root.Overlay.overlay

        width: 280
        height: Math.max(120, Math.min(280, (root.availableDevices?.length || 0) * 50 + 76))
        padding: 0
        modal: true
        dim: false
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

        background: Rectangle {
            color: "transparent"
        }

        contentItem: Rectangle {
            radius: Theme.cornerRadius * 2
            color: Theme.withAlpha(Theme.surfaceContainer, 0.98)
            border.color: Theme.withAlpha(Theme.outline, 0.6)
            border.width: 2

            ElevationShadow {
                anchors.fill: parent
                z: -1
                level: Theme.elevationLevel2
                fallbackOffset: 4
                targetRadius: parent.radius
                targetColor: parent.color
                borderColor: parent.border.color
                borderWidth: parent.border.width
                shadowEnabled: Theme.elevationEnabled
            }

            Column {
                    anchors.fill: parent
                    anchors.margins: Theme.spacingM
                    spacing: Theme.spacingS

                    StyledText {
                        text: "Output Device (" + (root.availableDevices?.length || 0) + ")"
                        font.pixelSize: Theme.fontSizeMedium
                        font.weight: Font.Medium
                        color: Theme.surfaceText
                        width: parent.width
                        horizontalAlignment: Text.AlignHCenter
                    }

                    ScrollView {
                        width: parent.width
                        height: parent.height - 32 - Theme.spacingS
                        clip: true

                        Column {
                            width: parent.width
                            spacing: Theme.spacingXS

                            Repeater {
                                model: root.availableDevices || []

                                Rectangle {
                                    id: deviceRow
                                    required property var modelData
                                    width: parent.width
                                    height: 44
                                    radius: Theme.cornerRadius
                                    color: deviceArea.containsMouse ? Theme.withAlpha(Theme.primary, 0.12) : Theme.withAlpha(Theme.surfaceContainerHigh, Theme.popupTransparency)
                                    border.color: modelData === AudioService.sink ? Theme.primary : Theme.withAlpha(Theme.outline, 0.2)
                                    border.width: modelData === AudioService.sink ? 2 : 1

                                    Row {
                                        anchors.left: parent.left
                                        anchors.leftMargin: Theme.spacingM
                                        anchors.right: parent.right
                                        anchors.rightMargin: Theme.spacingM
                                        anchors.verticalCenter: parent.verticalCenter
                                        spacing: Theme.spacingM

                                        DankIcon {
                                            anchors.verticalCenter: parent.verticalCenter
                                            name: root.getAudioDeviceIcon(deviceRow.modelData)
                                            size: 18
                                            color: deviceRow.modelData === AudioService.sink ? Theme.primary : Theme.surfaceText
                                        }

                                        StyledText {
                                            anchors.verticalCenter: parent.verticalCenter
                                            width: parent.width - 18 - Theme.spacingM
                                            text: AudioService.displayName(deviceRow.modelData)
                                            font.pixelSize: Theme.fontSizeSmall
                                            font.weight: deviceRow.modelData === AudioService.sink ? Font.Medium : Font.Normal
                                            color: Theme.surfaceText
                                            elide: Text.ElideRight
                                            wrapMode: Text.NoWrap
                                        }
                                    }

                                    MouseArea {
                                        id: deviceArea
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: {
                                            if (deviceRow.modelData?.name) {
                                                AudioService.setDefaultSinkByName(deviceRow.modelData.name);
                                                deviceFlyout.close();
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

    Item {
        id: shell
        width: parent.width
        implicitHeight: contentCard.implicitHeight
        height: implicitHeight

        Rectangle {
            id: contentCard
            width: parent.width
            implicitHeight: (root.showNoPlayerNow ? noPlayerState.implicitHeight : cardColumn.implicitHeight) + Theme.spacingL * 2
            radius: Theme.cornerRadius * 1.5
            color: "transparent"
            clip: true

            Item {
                anchors.fill: parent
                visible: !root.showNoPlayerNow && (activePlayer?.trackArtUrl || "").length > 0

                Image {
                    id: artworkImage
                    anchors.fill: parent
                    source: root.activePlayer?.trackArtUrl || ""
                    fillMode: Image.PreserveAspectCrop
                    visible: false
                    asynchronous: true
                    cache: true
                }

                Item {
                    id: blurredBg
                    anchors.fill: parent
                    visible: false

                    MultiEffect {
                        anchors.fill: parent
                        source: artworkImage
                        blurEnabled: true
                        blurMax: 64
                        blur: 0.8
                        saturation: -0.2
                        brightness: -0.25
                    }
                }

                Rectangle {
                    id: maskRect
                    anchors.fill: parent
                    radius: contentCard.radius
                    visible: false
                    layer.enabled: true
                }

                MultiEffect {
                    anchors.fill: parent
                    source: blurredBg
                    maskEnabled: true
                    maskSource: maskRect
                    maskThresholdMin: 0.5
                    maskSpreadAtMin: 1.0
                    opacity: 0.75
                }

                Rectangle {
                    anchors.fill: parent
                    radius: contentCard.radius
                    color: Theme.surface
                    opacity: 0.3
                }
            }

            Column {
                id: cardColumn
                width: parent.width - Theme.spacingL * 2 - (sideRail.width + Theme.spacingM)
                x: Theme.spacingL
                y: Theme.spacingL
                spacing: Theme.spacingM
                visible: !root.showNoPlayerNow

                Item {
                    width: parent.width
                    height: 140

                    // MediaArtwork is the current DMS album-art component
                    // (DankAlbumArt was removed after 1.6.2). It takes a
                    // resolved URL rather than a player.
                    MediaArtwork {
                        anchors.centerIn: parent
                        width: 140
                        height: 140
                        artUrl: root.activePlayer?.trackArtUrl || ""
                    }
                }

                Column {
                    width: parent.width
                    spacing: 4

                    StyledText {
                        text: root.activePlayer?.trackTitle || "Unknown Track"
                        font.pixelSize: Theme.fontSizeLarge
                        font.weight: Font.Bold
                        color: Theme.surfaceText
                        width: parent.width
                        horizontalAlignment: Text.AlignHCenter
                        elide: Text.ElideRight
                        wrapMode: Text.WordWrap
                        maximumLineCount: 2
                    }

                    StyledText {
                        text: root.activePlayer?.trackArtist || (root.activePlayer?.identity || "Unknown Artist")
                        font.pixelSize: Theme.fontSizeMedium
                        color: Theme.surfaceTextMedium
                        width: parent.width
                        horizontalAlignment: Text.AlignHCenter
                        elide: Text.ElideRight
                        wrapMode: Text.NoWrap
                    }

                    StyledText {
                        text: root.activePlayer?.trackAlbum || ""
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceTextSecondary
                        width: parent.width
                        horizontalAlignment: Text.AlignHCenter
                        elide: Text.ElideRight
                        wrapMode: Text.NoWrap
                        visible: text.length > 0
                    }
                }

                Column {
                    width: parent.width
                    spacing: Theme.spacingXXS

                    DankSeekbar {
                        width: parent.width
                        height: 20
                        activePlayer: root.activePlayer
                        // DankSeekbar.canSeek requires stableLength > 0; without
                        // it the bar renders but silently refuses every seek.
                        stableLength: root.stableLength
                        isSeeking: root.isSeeking
                        onIsSeekingChanged: root.isSeeking = isSeeking
                    }

                    Item {
                        width: parent.width
                        height: 16

                        StyledText {
                            anchors.left: parent.left
                            anchors.verticalCenter: parent.verticalCenter
                            text: {
                                if (!root.activePlayer)
                                    return "0:00";
                                const rawPos = Math.max(0, root.activePlayer.position || 0);
                                const pos = root.stableLength ? rawPos % Math.max(1, root.stableLength) : rawPos;
                                const minutes = Math.floor(pos / 60);
                                const seconds = Math.floor(pos % 60);
                                return minutes + ":" + (seconds < 10 ? "0" : "") + seconds;
                            }
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceVariantText
                        }

                        StyledText {
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            text: {
                                if (!root.activePlayer || root.stableLength <= 0)
                                    return "--:--";
                                const minutes = Math.floor(root.stableLength / 60);
                                const seconds = Math.floor(root.stableLength % 60);
                                return minutes + ":" + (seconds < 10 ? "0" : "") + seconds;
                            }
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceVariantText
                        }
                    }
                }

                Row {
                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: Theme.spacingM

                    Item {
                        width: 50
                        height: 50
                        visible: root.activePlayer && root.activePlayer.shuffleSupported

                        Rectangle {
                            width: 40
                            height: 40
                            radius: 20
                            anchors.centerIn: parent
                            color: shuffleArea.containsMouse ? Theme.withAlpha(Theme.primary, 0.12) : "transparent"

                            DankIcon {
                                anchors.centerIn: parent
                                name: "shuffle"
                                size: 20
                                color: root.activePlayer && root.activePlayer.shuffle ? Theme.primary : Theme.surfaceText
                            }

                            MouseArea {
                                id: shuffleArea
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    if (root.activePlayer && root.activePlayer.canControl && root.activePlayer.shuffleSupported)
                                        root.activePlayer.shuffle = !root.activePlayer.shuffle;
                                }
                            }
                        }
                    }

                    Item {
                        width: 50
                        height: 50

                        Rectangle {
                            width: 40
                            height: 40
                            radius: 20
                            anchors.centerIn: parent
                            color: prevArea.containsMouse ? Theme.withAlpha(Theme.surfaceContainerHigh, Theme.popupTransparency) : "transparent"

                            DankIcon {
                                anchors.centerIn: parent
                                name: "skip_previous"
                                size: 24
                                color: Theme.surfaceText
                            }

                            MouseArea {
                                id: prevArea
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: MprisController.previousOrRewind()
                            }
                        }
                    }

                    Item {
                        width: 50
                        height: 50

                        Rectangle {
                            width: 50
                            height: 50
                            radius: 25
                            anchors.centerIn: parent
                            color: Theme.primary

                            DankIcon {
                                anchors.centerIn: parent
                                name: root.activePlayer && root.activePlayer.playbackState === MprisPlaybackState.Playing ? "pause" : "play_arrow"
                                size: 28
                                color: Theme.background
                                weight: 500
                            }

                            MouseArea {
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                enabled: !!(root.activePlayer && root.activePlayer.canTogglePlaying)
                                onClicked: root.activePlayer.togglePlaying()
                            }
                        }
                    }

                    Item {
                        width: 50
                        height: 50

                        Rectangle {
                            width: 40
                            height: 40
                            radius: 20
                            anchors.centerIn: parent
                            color: nextArea.containsMouse ? Theme.withAlpha(Theme.surfaceContainerHigh, Theme.popupTransparency) : "transparent"

                            DankIcon {
                                anchors.centerIn: parent
                                name: "skip_next"
                                size: 24
                                color: Theme.surfaceText
                            }

                            MouseArea {
                                id: nextArea
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.activePlayer && root.activePlayer.next()
                            }
                        }
                    }

                    Item {
                        width: 50
                        height: 50
                        visible: root.activePlayer && root.activePlayer.loopSupported

                        Rectangle {
                            width: 40
                            height: 40
                            radius: 20
                            anchors.centerIn: parent
                            color: repeatArea.containsMouse ? Theme.withAlpha(Theme.primary, 0.12) : "transparent"

                            DankIcon {
                                anchors.centerIn: parent
                                name: {
                                    if (!root.activePlayer)
                                        return "repeat";
                                    return root.activePlayer.loopState === MprisLoopState.Track ? "repeat_one" : "repeat";
                                }
                                size: 20
                                color: root.activePlayer && root.activePlayer.loopState !== MprisLoopState.None ? Theme.primary : Theme.surfaceText
                            }

                            MouseArea {
                                id: repeatArea
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    if (!root.activePlayer || !root.activePlayer.canControl || !root.activePlayer.loopSupported)
                                        return;
                                    switch (root.activePlayer.loopState) {
                                    case MprisLoopState.None:
                                        root.activePlayer.loopState = MprisLoopState.Playlist;
                                        break;
                                    case MprisLoopState.Playlist:
                                        root.activePlayer.loopState = MprisLoopState.Track;
                                        break;
                                    case MprisLoopState.Track:
                                        root.activePlayer.loopState = MprisLoopState.None;
                                        break;
                                    }
                                }
                            }
                        }
                    }
                }
            }

            Column {
                id: noPlayerState
                anchors.centerIn: parent
                spacing: Theme.spacingM
                visible: root.showNoPlayerNow

                DankIcon {
                    name: "music_note"
                    size: Theme.iconSize * 3
                    color: Theme.surfaceTextSecondary
                    anchors.horizontalCenter: parent.horizontalCenter
                }

                StyledText {
                    text: "No Active Players"
                    font.pixelSize: Theme.fontSizeLarge
                    color: Theme.surfaceTextMedium
                    anchors.horizontalCenter: parent.horizontalCenter
                }
            }

            component MiniButton: Rectangle {
                id: buttonRoot
                property string iconName: ""
                property color iconColor: Theme.surfaceText
                property bool enabledState: true
                property string tooltipText: ""
                property bool active: false
                property color activeColor: Theme.primary
                signal clicked
                signal wheeled(var wheelEvent)

                width: 40
                height: 40
                radius: 20
                color: {
                    if (buttonArea.containsMouse)
                        return Theme.withAlpha(buttonRoot.active ? buttonRoot.activeColor : Theme.primary, buttonRoot.active ? 0.28 : 0.15);
                    if (buttonRoot.active)
                        return Theme.withAlpha(buttonRoot.activeColor, 0.16);
                    return "transparent";
                }
                border.color: buttonRoot.active ? buttonRoot.activeColor : Theme.outlineStrong
                border.width: 1
                opacity: enabledState ? 1 : 0.45

                DankIcon {
                    anchors.centerIn: parent
                    name: buttonRoot.iconName
                    size: 18
                    color: buttonRoot.iconColor
                }

                MouseArea {
                    id: buttonArea
                    anchors.fill: parent
                    hoverEnabled: true
                    enabled: buttonRoot.enabledState
                    cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                    onClicked: buttonRoot.clicked()
                    onWheel: wheelEvent => buttonRoot.wheeled(wheelEvent)
                    onEntered: {
                        if (buttonRoot.tooltipText.length > 0)
                            sharedTooltip.show(buttonRoot.tooltipText, buttonRoot, 0, 0, "left");
                    }
                    onExited: sharedTooltip.hide()
                }
            }


            Column {
                id: sideRail
                x: parent.width - width - Theme.spacingM
                y: Theme.spacingL
                spacing: Theme.spacingS
                z: 250
                visible: !root.showNoPlayerNow

                MiniButton {
                    id: volumeButton
                    enabledState: root.volumeAvailable
                    iconName: volumeFlyout.visible ? "expand_less" : root.getVolumeIcon()
                    iconColor: root.volumeAvailable && root.currentVolume > 0 ? Theme.primary : Theme.withAlpha(Theme.surfaceText, root.volumeAvailable ? 1.0 : 0.5)
                    tooltipText: "Volume"
                    onClicked: {
                        deviceFlyout.close();
                        if (volumeFlyout.visible)
                            volumeFlyout.close();
                        else
                            root.openFlyout(volumeFlyout, volumeButton);
                    }
                    onWheeled: wheelEvent => {
                        wheelEvent.accepted = true;
                        root.adjustVolume(wheelEvent.angleDelta.y > 0 ? 5 : -5);
                    }
                }

                MiniButton {
                    id: audioDevicesButton
                    enabledState: true
                    iconName: deviceFlyout.visible ? "expand_less" : "speaker"
                    tooltipText: "Output Device"
                    onClicked: {
                        volumeFlyout.close();
                        if (deviceFlyout.visible)
                            deviceFlyout.close();
                        else
                            root.openFlyout(deviceFlyout, audioDevicesButton);
                    }
                }

                MiniButton {
                    enabledState: root.heartEnabled
                    active: !!(root.widgetRoot && root.widgetRoot.isSavedCurrent)
                    activeColor: Theme.error
                    iconName: active ? "favorite" : "favorite_border"
                    iconColor: active ? Theme.error : Theme.surfaceText
                    tooltipText: root.heartTooltip
                    onClicked: root.widgetRoot && root.widgetRoot.toggleSaved()
                }
            }
        }

    }
}
