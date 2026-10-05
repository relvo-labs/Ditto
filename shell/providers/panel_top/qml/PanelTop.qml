import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Services.Pipewire
import Quickshell.Networking

/// `ui.panel_top` provider: workspaces, the focused window, volume, network,
/// clock, the entrances to the four centers and the power menu. Nothing here
/// polls; desktop values arrive with a snapshot or an event. Volume and
/// network are UI reads of the system (PipeWire, NetworkManager) and are not
/// Ditto configuration.
///
/// Provider interface (plan/03/04 §2.1): the host sets client, tokens, config,
/// screen, slotName and shown; the provider declares reservedEdge, ready,
/// healthy() and release(). It reaches Core only through `client`.
///
/// Optionally a panel offers `statusRegion`, an Item in its bar where the
/// Shell places the mounted `ui.status_item` members (shell/core/StatusArea.qml).
/// The panel lays the region out and nothing more: which items are in it,
/// and in what order, is the Shell's. A panel without one still works; the
/// Shell then shows the items in a strip of its own.
Scope {
    id: provider

    property var client: null
    property var tokens: null
    property var config: ({})
    property var screen: null
    property string slotName: ""
    property string entryId: ""
    property bool shown: false

    readonly property string reservedEdge: "top"
    readonly property Item statusRegion: statusRow
    property bool ready: false
    property bool menuOpen: false

    function healthy() {
        return ready && client !== null && tokens !== null;
    }

    function release() {
        menuOpen = false;
        shown = false;
    }

    function t(source) {
        return client ? client.t(source) : source;
    }

    function invoke(commandId) {
        menuOpen = false;
        client.capability("desktop.commands.invoke", { command_id: commandId, args: {} }, null, function (error) {
            console.log("ditto-panel command refused: " + error.name + " " + error.message);
        });
    }

    function session(action) {
        menuOpen = false;
        client.capability("desktop.session." + action, {}, null, function (error) {
            console.log("ditto-panel session " + action + " refused: " + error.name + " " + error.message);
        });
    }

    Component.onCompleted: ready = true

    PwObjectTracker {
        objects: provider.shown && Pipewire.defaultAudioSink ? [Pipewire.defaultAudioSink] : []
    }

    SystemClock {
        id: clock
        enabled: provider.shown
        precision: SystemClock.Minutes
    }

    PanelWindow {
        id: panel

        visible: provider.shown
        anchors { top: true; left: true; right: true }
        implicitHeight: 34
        exclusiveZone: provider.shown ? 34 : 0
        color: "transparent"
        // Mapped without keyboard interactivity, then on demand: a surface
        // that maps on demand is given the keyboard focus by the compositor,
        // so swapping a Dock would take focus from the window in use.
        property bool mapped: false
        onVisibleChanged: if (!visible) mapped = false
        Timer {
            interval: 250
            running: panel.visible && !panel.mapped
            onTriggered: panel.mapped = true
        }
        WlrLayershell.keyboardFocus: mapped ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None
        WlrLayershell.namespace: "ditto-panel-top"

        Rectangle {
            anchors.fill: parent
            anchors.margins: 2
            radius: provider.tokens.radiusSmall
            color: provider.tokens.surface
            border.color: provider.tokens.border
            border.width: 1
            opacity: provider.tokens.surfaceOpacity
        }

        Row {
            anchors.left: parent.left
            anchors.leftMargin: provider.tokens.spaceWide
            anchors.verticalCenter: parent.verticalCenter
            spacing: provider.tokens.space

            Rectangle {
                width: brand.implicitWidth + provider.tokens.spaceWide
                height: 22
                radius: provider.tokens.radiusSmall
                color: menuArea.containsMouse || activeFocus ? provider.tokens.surfaceStrong : "transparent"
                activeFocusOnTab: true
                Accessible.role: Accessible.Button
                Accessible.name: provider.t(qsTr("Ditto 選單"))
                Keys.onReturnPressed: provider.menuOpen = !provider.menuOpen
                Keys.onSpacePressed: provider.menuOpen = !provider.menuOpen

                Text {
                    id: brand
                    anchors.centerIn: parent
                    text: "Ditto ▾"
                    color: provider.tokens.foreground
                    font.pixelSize: provider.tokens.fontSmall
                    font.bold: true
                }

                Rectangle {
                    anchors.fill: parent
                    anchors.margins: -2
                    radius: parent.radius + 2
                    color: "transparent"
                    border.color: provider.tokens.focus
                    border.width: parent.activeFocus ? 2 : 0
                }

                MouseArea {
                    id: menuArea
                    anchors.fill: parent
                    hoverEnabled: true
                    onClicked: provider.menuOpen = !provider.menuOpen
                }
            }

            Repeater {
                model: provider.client ? provider.client.workspaces : []

                Rectangle {
                    required property var modelData
                    width: label.implicitWidth + provider.tokens.spaceWide
                    height: 22
                    radius: provider.tokens.radiusSmall
                    color: modelData.active ? provider.tokens.accent : "transparent"
                    border.color: provider.tokens.border
                    border.width: modelData.active ? 0 : 1
                    activeFocusOnTab: true
                    Accessible.role: Accessible.Button
                    Accessible.name: provider.t(qsTr("工作區 %1")).arg(modelData.name)
                        + (modelData.active ? provider.t(qsTr("（目前）")) : "")

                    Text {
                        id: label
                        anchors.centerIn: parent
                        text: modelData.name
                        color: modelData.active ? provider.tokens.onAccent : provider.tokens.foreground
                        font.pixelSize: provider.tokens.fontSmall
                    }

                    // Focus is visible on its own, not only by colour.
                    Rectangle {
                        anchors.fill: parent
                        anchors.margins: -2
                        radius: parent.radius + 2
                        color: "transparent"
                        border.color: provider.tokens.focus
                        border.width: parent.activeFocus ? 2 : 0
                    }

                    Keys.onReturnPressed: provider.client.activateWorkspace(modelData.id)
                    Keys.onSpacePressed: provider.client.activateWorkspace(modelData.id)

                    MouseArea {
                        anchors.fill: parent
                        enabled: provider.client.capabilityAvailable("desktop.workspaces.activate")
                        onClicked: provider.client.activateWorkspace(modelData.id)
                    }
                }
            }
        }

        Text {
            anchors.centerIn: parent
            width: parent.width * 0.34
            elide: Text.ElideRight
            horizontalAlignment: Text.AlignHCenter
            color: provider.tokens.foreground
            font.pixelSize: provider.tokens.fontBody
            text: {
                const focused = provider.client ? provider.client.windows.find(item => item.focused) : null;
                return focused ? focused.title : provider.t(qsTr("沒有作用中的視窗"));
            }
        }

        Row {
            anchors.right: parent.right
            anchors.rightMargin: provider.tokens.spaceWide
            anchors.verticalCenter: parent.verticalCenter
            spacing: provider.tokens.spaceWide

            Text {
                color: provider.client && provider.client.online ? provider.tokens.foregroundMuted : provider.tokens.warning
                font.pixelSize: provider.tokens.fontSmall
                text: provider.client && provider.client.online
                    ? provider.t(qsTr("%1 個視窗")).arg(provider.client.windows.length)
                    : (provider.client ? provider.client.status : "")
            }

            /// Volume: shown and nudged here; details open pavucontrol.
            Text {
                id: volume
                readonly property var sink: Pipewire.defaultAudioSink
                readonly property bool known: sink !== null && sink.audio !== null && Pipewire.ready
                color: provider.tokens.foregroundMuted
                font.pixelSize: provider.tokens.fontSmall
                text: !known ? provider.t(qsTr("音量不可用"))
                    : sink.audio.muted ? provider.t(qsTr("音量 靜音"))
                    : provider.t(qsTr("音量 %1%")).arg(Math.round(sink.audio.volume * 100))
                Accessible.role: Accessible.Button
                Accessible.name: text

                MouseArea {
                    anchors.fill: parent
                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                    onClicked: mouse => {
                        if (mouse.button === Qt.RightButton) {
                            provider.client.launchApp("pavucontrol");
                        } else if (volume.known) {
                            volume.sink.audio.muted = !volume.sink.audio.muted;
                        }
                    }
                    onWheel: wheel => {
                        if (volume.known) {
                            const step = wheel.angleDelta.y > 0 ? 0.05 : -0.05;
                            volume.sink.audio.volume = Math.max(0, Math.min(1.5, volume.sink.audio.volume + step));
                        }
                    }
                }
            }

            /// Network: NetworkManager's state, read only; details open the
            /// connection editor.
            Text {
                id: network
                readonly property bool connected: {
                    const devices = Networking.devices ? Networking.devices.values : [];
                    for (let index = 0; index < devices.length; index += 1) {
                        if (devices[index].connected) {
                            return true;
                        }
                    }
                    return false;
                }
                color: connected ? provider.tokens.foregroundMuted : provider.tokens.warning
                font.pixelSize: provider.tokens.fontSmall
                text: connected ? provider.t(qsTr("網路已連線")) : provider.t(qsTr("網路未連線"))
                Accessible.role: Accessible.Button
                Accessible.name: text

                MouseArea {
                    anchors.fill: parent
                    onClicked: provider.client.launchApp("nm-connection-editor")
                }
            }

            /// Status items (`ui.status_item`), placed here by the Shell.
            Row {
                id: statusRow
                spacing: provider.tokens.spaceWide
                Accessible.role: Accessible.StatusBar
                Accessible.name: provider.t(qsTr("狀態列項目"))
            }

            Text {
                color: provider.tokens.foreground
                font.pixelSize: provider.tokens.fontSmall
                text: Qt.formatDateTime(clock.date, "HH:mm")
            }
        }
    }

    /// The Ditto menu: the four centers, the launcher and the session.
    PopupWindow {
        id: menu
        visible: provider.shown && provider.menuOpen
        anchor.window: panel
        anchor.rect.x: 8
        anchor.rect.y: panel.height
        implicitWidth: 220
        implicitHeight: menuColumn.implicitHeight + provider.tokens.space * 2
        color: "transparent"

        Rectangle {
            anchors.fill: parent
            radius: provider.tokens.radiusMedium
            color: provider.tokens.surfaceStrong
            border.color: provider.tokens.border
            border.width: 1
        }

        Column {
            id: menuColumn
            anchors.fill: parent
            anchors.margins: provider.tokens.space
            spacing: 2

            Repeater {
                model: [
                    { label: qsTr("開啟啟動器"), command: "launcher.toggle" },
                    { label: qsTr("組合中心"), command: "composition.open" },
                    { label: qsTr("插件中心"), command: "plugins.open" },
                    { label: qsTr("變更紀錄"), command: "history.open" },
                    { label: qsTr("個人化設定"), command: "personalization.open" },
                    { label: qsTr("鎖定畫面"), session: "lock" },
                    { label: qsTr("登出"), session: "logout" },
                    { label: qsTr("暫停"), session: "suspend" },
                    { label: qsTr("關機"), session: "poweroff" }
                ]

                Rectangle {
                    required property var modelData
                    readonly property string capabilityId: modelData.session
                        ? "desktop.session." + modelData.session : "desktop.commands.invoke"
                    visible: provider.client && provider.client.capabilityAvailable(capabilityId)
                    width: menuColumn.width
                    height: visible ? 28 : 0
                    radius: provider.tokens.radiusSmall
                    color: itemArea.containsMouse || activeFocus ? provider.tokens.surface : "transparent"
                    activeFocusOnTab: true
                    Accessible.role: Accessible.MenuItem
                    Accessible.name: itemText.text
                    Keys.onReturnPressed: activate()
                    Keys.onSpacePressed: activate()

                    function activate() {
                        if (modelData.session) {
                            provider.session(modelData.session);
                        } else {
                            provider.invoke(modelData.command);
                        }
                    }

                    Text {
                        id: itemText
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.left: parent.left
                        anchors.leftMargin: provider.tokens.space
                        text: provider.t(modelData.label)
                        color: provider.tokens.foreground
                        font.pixelSize: provider.tokens.fontBody
                    }

                    Rectangle {
                        anchors.fill: parent
                        radius: parent.radius
                        color: "transparent"
                        border.color: provider.tokens.focus
                        border.width: parent.activeFocus ? 2 : 0
                    }

                    MouseArea {
                        id: itemArea
                        anchors.fill: parent
                        hoverEnabled: true
                        onClicked: parent.activate()
                    }
                }
            }
        }
    }
}
