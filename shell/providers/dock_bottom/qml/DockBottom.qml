import QtQuick
import Quickshell
import Quickshell.Wayland

/// Dock A (`ui.dock`): a bottom-centred row of the running windows. Its data is
/// `client.windows` only — the running list, nothing pinned — which is what
/// makes it a different provider from the pill dock, not a restyle.
Scope {
    id: provider

    property var client: null
    property var tokens: null
    property var config: ({})
    property var screen: null
    property string slotName: ""
    property string entryId: ""
    property bool shown: false

    readonly property string reservedEdge: "bottom"
    property bool ready: false

    function healthy() {
        return ready && client !== null && tokens !== null;
    }

    function release() {
        shown = false;
    }

    function t(source) {
        return client ? client.t(source) : source;
    }

    // Presentation-only projection: window updates must not reset input.
    readonly property var windows: client ? client.windows : []
    ListModel { id: tileModel; dynamicRoles: true }
    function syncTiles() {
        if (!ready) return;
        for (let i = tileModel.count - 1; i >= 0; --i) {
            if (!windows.some(window => window.id === tileModel.get(i).key)) tileModel.remove(i);
        }
        for (let i = 0; i < windows.length; ++i) {
            let found = i;
            while (found < tileModel.count && tileModel.get(found).key !== windows[i].id) ++found;
            if (found === tileModel.count) {
                tileModel.insert(i, { key: windows[i].id, entryData: windows[i] });
            } else {
                if (found !== i) tileModel.move(found, i, 1);
                if (JSON.stringify(tileModel.get(i).entryData) !== JSON.stringify(windows[i]))
                    tileModel.setProperty(i, "entryData", windows[i]);
            }
        }
    }
    onWindowsChanged: syncTiles()
    Component.onCompleted: { ready = true; syncTiles(); }

    PanelWindow {
        id: dock

        visible: provider.shown
        anchors { bottom: true }
        implicitWidth: Math.max(220, entries.implicitWidth + provider.tokens.spaceSection * 2)
        implicitHeight: 56
        exclusiveZone: provider.shown ? 56 : 0
        color: "transparent"
        // Mapped without keyboard interactivity, then on demand: a surface
        // that maps on demand is given the keyboard focus by the compositor,
        // so swapping a Dock would take focus from the window in use.
        property bool mapped: false
        onVisibleChanged: if (!visible) mapped = false
        Timer {
            interval: 250
            running: dock.visible && !dock.mapped
            onTriggered: dock.mapped = true
        }
        WlrLayershell.keyboardFocus: mapped ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None
        WlrLayershell.namespace: "ditto-dock-bottom"

        Rectangle {
            anchors.fill: parent
            anchors.margins: provider.tokens.space
            radius: provider.tokens.radiusMedium
            color: provider.tokens.surface
            border.color: provider.tokens.border
            border.width: 1
            opacity: provider.tokens.surfaceOpacity
        }

        Row {
            id: entries
            anchors.centerIn: parent
            spacing: provider.tokens.space

            Repeater {
                model: tileModel

                Rectangle {
                    required property var entryData
                    readonly property var modelData: entryData
                    width: 150
                    height: 34
                    radius: provider.tokens.radiusSmall
                    color: modelData.focused ? provider.tokens.surfaceStrong : "transparent"
                    border.color: provider.tokens.border
                    border.width: 1
                    activeFocusOnTab: true
                    Accessible.role: Accessible.Button
                    Accessible.name: modelData.title + (modelData.focused ? provider.t(qsTr("（作用中）")) : "")

                    Row {
                        anchors.fill: parent
                        anchors.margins: provider.tokens.space
                        spacing: provider.tokens.spaceTight

                        Text {
                            width: parent.width - closeButton.width - provider.tokens.spaceTight
                            elide: Text.ElideRight
                            color: provider.tokens.foreground
                            font.pixelSize: provider.tokens.fontSmall
                            text: (modelData.focused ? "▸ " : "") + modelData.app_id
                        }

                        Text {
                            id: closeButton
                            // An action the compositor cannot perform is not
                            // shown as a button that would only fail.
                            visible: provider.client.capabilityAvailable("desktop.windows.close_request")
                            color: provider.tokens.foregroundMuted
                            font.pixelSize: provider.tokens.fontSmall
                            text: "✕"
                            Accessible.role: Accessible.Button
                            Accessible.name: provider.t(qsTr("關閉"))

                            MouseArea {
                                anchors.fill: parent
                                onClicked: provider.client.closeWindow(modelData.id)
                            }
                        }
                    }

                    Rectangle {
                        anchors.fill: parent
                        anchors.margins: -2
                        radius: parent.radius + 2
                        color: "transparent"
                        border.color: provider.tokens.focus
                        border.width: parent.activeFocus ? 2 : 0
                    }

                    Keys.onReturnPressed: provider.client.focusWindow(modelData.id)
                    Keys.onSpacePressed: provider.client.focusWindow(modelData.id)
                    Keys.onDeletePressed: provider.client.closeWindow(modelData.id)

                    MouseArea {
                        anchors.fill: parent
                        z: -1
                        onClicked: provider.client.focusWindow(modelData.id)
                    }
                }
            }

            Text {
                visible: !provider.client || provider.client.windows.length === 0
                color: provider.tokens.foregroundMuted
                font.pixelSize: provider.tokens.fontSmall
                text: provider.client && provider.client.online
                    ? provider.t(qsTr("目前沒有執行中的視窗"))
                    : (provider.client ? provider.client.status : "")
            }
        }
    }
}
