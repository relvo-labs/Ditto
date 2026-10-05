import QtQuick
import Quickshell
import Quickshell.Wayland

/// Launcher B (`ui.launcher`): a centred search box with live results. Typing
/// searches, Up/Down selects, Enter launches, Esc closes. The fuzzy matching
/// is Core's index (`desktop.launcher.search`); this provider keeps no index
/// of its own, so swapping launchers rebuilds nothing.
Scope {
    id: provider

    property var client: null
    property var tokens: null
    property var config: ({})
    property var screen: null
    property string slotName: ""
    property string entryId: ""
    property bool shown: false

    readonly property string reservedEdge: "none"
    property bool ready: false
    property bool isOpen: false
    property var results: []
    property string status: ""
    property int selected: 0
    property int generation: 0

    function healthy() {
        return ready && client !== null && tokens !== null;
    }

    function release() {
        isOpen = false;
        shown = false;
    }

    function t(source) {
        return client ? client.t(source) : source;
    }

    function open() {
        if (!shown) {
            return;
        }
        isOpen = true;
        query.text = "";
        results = [];
        selected = 0;
        status = "";
        query.forceActiveFocus();
    }

    function close() {
        isOpen = false;
    }

    function toggle() {
        if (isOpen) {
            close();
        } else {
            open();
        }
    }

    /// Answers can arrive out of order; only the newest query's answer is used.
    function search(text) {
        generation += 1;
        const mine = generation;
        if (text.trim().length === 0) {
            results = [];
            status = "";
            return;
        }
        client.capability("desktop.launcher.search", { query: text, limit: 8 }, function (result) {
            if (mine !== provider.generation) {
                return;
            }
            provider.results = result.apps;
            provider.selected = 0;
            provider.status = result.apps.length === 0 ? provider.t(qsTr("沒有符合的應用程式")) : "";
        }, function (error) {
            if (mine === provider.generation) {
                provider.status = provider.t(qsTr("搜尋暫不可用"));
            }
        });
    }

    function launch(app) {
        if (!app) {
            return;
        }
        client.launchApp(app.app_id, function () {
            provider.close();
        }, function (error) {
            provider.status = provider.t(qsTr("無法啟動「%1」")).arg(app.name);
        });
    }

    Component.onCompleted: ready = true

    PanelWindow {
        id: surface

        visible: provider.shown && provider.isOpen
        anchors { top: true; bottom: true; left: true; right: true }
        exclusionMode: ExclusionMode.Ignore
        color: "transparent"
        focusable: true
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: provider.isOpen ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
        WlrLayershell.namespace: "ditto-launcher-search"

        MouseArea {
            anchors.fill: parent
            onClicked: provider.close()
        }

        Rectangle {
            id: box
            anchors.horizontalCenter: parent.horizontalCenter
            y: parent.height * 0.22
            width: 560
            height: column.implicitHeight + provider.tokens.spaceWide * 2
            radius: provider.tokens.radiusLarge
            color: provider.tokens.surfaceStrong
            border.color: provider.tokens.border
            border.width: 1

            MouseArea {
                anchors.fill: parent
            }

            Column {
                id: column
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: provider.tokens.spaceWide
                spacing: provider.tokens.space

                Rectangle {
                    width: parent.width
                    height: 40
                    radius: provider.tokens.radiusMedium
                    color: provider.tokens.surface
                    border.color: query.activeFocus ? provider.tokens.focus : provider.tokens.border
                    border.width: query.activeFocus ? 2 : 1

                    TextInput {
                        id: query
                        anchors.fill: parent
                        anchors.leftMargin: provider.tokens.spaceWide
                        anchors.rightMargin: provider.tokens.spaceWide
                        verticalAlignment: TextInput.AlignVCenter
                        color: provider.tokens.foreground
                        font.pixelSize: provider.tokens.fontTitle
                        selectByMouse: true
                        Accessible.role: Accessible.EditableText
                        Accessible.name: provider.t(qsTr("搜尋應用程式"))
                        onTextEdited: provider.search(text)
                        Keys.onEscapePressed: provider.close()
                        Keys.onUpPressed: provider.selected = Math.max(0, provider.selected - 1)
                        Keys.onDownPressed: provider.selected = Math.min(provider.results.length - 1, provider.selected + 1)
                        Keys.onReturnPressed: provider.launch(provider.results[provider.selected])
                        Keys.onEnterPressed: provider.launch(provider.results[provider.selected])

                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            visible: query.text.length === 0
                            text: provider.t(qsTr("輸入應用程式名稱"))
                            color: provider.tokens.foregroundMuted
                            font.pixelSize: provider.tokens.fontTitle
                        }
                    }
                }

                Repeater {
                    model: provider.results

                    Rectangle {
                        required property var modelData
                        required property int index
                        width: column.width
                        height: 36
                        radius: provider.tokens.radiusSmall
                        color: index === provider.selected ? provider.tokens.accent : "transparent"
                        Accessible.role: Accessible.ListItem
                        Accessible.name: modelData.name
                        Accessible.selected: index === provider.selected

                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.left: parent.left
                            anchors.leftMargin: provider.tokens.space
                            text: modelData.name + (modelData.generic_name ? "  ·  " + modelData.generic_name : "")
                            color: index === provider.selected ? provider.tokens.onAccent : provider.tokens.foreground
                            font.pixelSize: provider.tokens.fontBody
                        }

                        MouseArea {
                            anchors.fill: parent
                            onClicked: provider.launch(modelData)
                        }
                    }
                }

                Text {
                    visible: text.length > 0
                    text: provider.status
                    color: provider.tokens.foregroundMuted
                    font.pixelSize: provider.tokens.fontSmall
                }
            }
        }
    }
}
