import QtQuick
import Quickshell
import Quickshell.Wayland

/// `ui.tasks_panel`: the tasks service's panel. The service is a Cordis plugin
/// in hostd (`svc.tasks`); this panel only shows and edits through
/// `desktop.tasks.*`. When the service runs on demonstration data the panel
/// says so; when the service is unavailable (host down, rescue mode) it says
/// that instead of showing an empty list as if there were no tasks.
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
    property bool expanded: false
    property bool watching: false
    property string notice: ""

    readonly property var snapshot: client ? client.tasks : null
    readonly property var openTasks: snapshot ? snapshot.tasks.filter(task => !task.done) : []
    readonly property bool unavailable: !client || client.tasksStatus === "unavailable"
    /// What the panel's header says right now (read by the Shell's `services`
    /// control line).
    readonly property string headerText: header.text
        || (client.mode === "rescue")

    function healthy() {
        return ready && client !== null && tokens !== null;
    }

    function release() {
        expanded = false;
        shown = false;
    }

    function t(source) {
        return client ? client.t(source) : source;
    }

    /// Data flows only while the panel is mounted and shown.
    onShownChanged: {
        if (shown && !watching && client) {
            watching = true;
            client.watchTasks();
        } else if (!shown && watching) {
            watching = false;
            client.unwatchTasks();
        }
    }

    Component.onDestruction: {
        if (watching && client) {
            client.unwatchTasks();
        }
    }

    function add(text) {
        if (text.trim().length === 0) {
            return;
        }
        client.capability("desktop.tasks.add", { text: text.trim() }, function () {
            provider.notice = "";
            field.text = "";
        }, function (error) {
            provider.notice = client.errorText(error);
        });
    }

    function complete(task) {
        client.capability("desktop.tasks.complete", { task_id: task.task_id }, null, function (error) {
            provider.notice = client.errorText(error);
        });
    }

    Component.onCompleted: ready = true

    PanelWindow {
        id: surface

        visible: provider.shown
        anchors { top: true; left: true }
        margins { top: 6; left: 8 }
        // Placed inside the other surfaces' zones, reserving none itself.
        exclusionMode: ExclusionMode.Normal
        exclusiveZone: 0
        implicitWidth: 300
        implicitHeight: provider.expanded ? Math.min(420, content.implicitHeight + provider.tokens.spaceWide * 2) : 40
        color: "transparent"
        focusable: provider.expanded
        WlrLayershell.layer: WlrLayer.Top
        WlrLayershell.keyboardFocus: provider.expanded ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None
        WlrLayershell.namespace: "ditto-tasks-panel"

        Rectangle {
            anchors.fill: parent
            radius: provider.tokens.radiusMedium
            color: provider.tokens.surfaceStrong
            border.color: provider.tokens.border
            border.width: 1
            opacity: provider.tokens.surfaceOpacity
        }

        Column {
            id: content
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: provider.tokens.space
            spacing: provider.tokens.space

            Item {
                width: parent.width
                height: 24
                activeFocusOnTab: true
                Accessible.role: Accessible.Button
                Accessible.name: header.text
                Keys.onReturnPressed: provider.expanded = !provider.expanded
                Keys.onSpacePressed: provider.expanded = !provider.expanded

                Text {
                    id: header
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.left: parent.left
                    anchors.leftMargin: provider.tokens.spaceTight
                    color: provider.tokens.foreground
                    font.pixelSize: provider.tokens.fontBody
                    font.bold: true
                    text: provider.unavailable ? provider.t(qsTr("待辦服務暫不可用"))
                        : !provider.snapshot ? provider.t(qsTr("待辦讀取中"))
                        : provider.t(qsTr("待辦 %1 項")).arg(provider.openTasks.length)
                }

                Rectangle {
                    visible: !!provider.snapshot && provider.snapshot.demo === true && !provider.unavailable
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.right: parent.right
                    width: demoLabel.implicitWidth + provider.tokens.space * 2
                    height: 20
                    radius: 10
                    color: provider.tokens.warning
                    Text {
                        id: demoLabel
                        anchors.centerIn: parent
                        text: provider.t(qsTr("示範資料"))
                        color: provider.tokens.statusForeground
                        font.pixelSize: provider.tokens.fontSmall
                    }
                }

                MouseArea {
                    anchors.fill: parent
                    onClicked: provider.expanded = !provider.expanded
                }
            }

            Text {
                visible: provider.expanded && provider.unavailable
                width: parent.width
                wrapMode: Text.WordWrap
                color: provider.tokens.foregroundMuted
                font.pixelSize: provider.tokens.fontSmall
                text: provider.client && provider.client.mode === "rescue"
                    ? provider.t(qsTr("救援模式不執行插件服務，待辦會在一般模式恢復。"))
                    : provider.t(qsTr("待辦服務沒有回應，已知的待辦沒有被刪除。服務恢復後會自動重新顯示。"))
            }

            Repeater {
                model: provider.expanded && !provider.unavailable ? provider.openTasks : []

                Rectangle {
                    required property var modelData
                    width: content.width
                    height: Math.max(28, taskText.implicitHeight + provider.tokens.space)
                    radius: provider.tokens.radiusSmall
                    color: activeFocus ? provider.tokens.surface : "transparent"
                    activeFocusOnTab: true
                    Accessible.role: Accessible.CheckBox
                    Accessible.name: modelData.text
                    Keys.onSpacePressed: provider.complete(modelData)
                    Keys.onReturnPressed: provider.complete(modelData)

                    Rectangle {
                        id: box
                        anchors.verticalCenter: parent.verticalCenter
                        x: provider.tokens.spaceTight
                        width: 14
                        height: 14
                        radius: 3
                        color: "transparent"
                        border.color: provider.tokens.foregroundMuted
                        border.width: 1
                        MouseArea {
                            anchors.fill: parent
                            anchors.margins: -6
                            onClicked: provider.complete(modelData)
                        }
                    }

                    Text {
                        id: taskText
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.left: box.right
                        anchors.leftMargin: provider.tokens.space
                        anchors.right: parent.right
                        wrapMode: Text.WordWrap
                        text: modelData.text
                        color: provider.tokens.foreground
                        font.pixelSize: provider.tokens.fontBody
                    }
                }
            }

            Rectangle {
                visible: provider.expanded && !provider.unavailable
                width: parent.width
                height: 30
                radius: provider.tokens.radiusSmall
                color: provider.tokens.surface
                border.color: field.activeFocus ? provider.tokens.focus : provider.tokens.border
                border.width: field.activeFocus ? 2 : 1

                TextInput {
                    id: field
                    anchors.fill: parent
                    anchors.leftMargin: provider.tokens.space
                    anchors.rightMargin: provider.tokens.space
                    verticalAlignment: TextInput.AlignVCenter
                    color: provider.tokens.foreground
                    font.pixelSize: provider.tokens.fontBody
                    selectByMouse: true
                    activeFocusOnTab: true
                    Accessible.role: Accessible.EditableText
                    Accessible.name: provider.t(qsTr("新增待辦"))
                    Keys.onReturnPressed: provider.add(text)
                    Keys.onEnterPressed: provider.add(text)

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: field.text.length === 0 && !field.activeFocus
                        text: provider.t(qsTr("新增待辦，按 Enter"))
                        color: provider.tokens.foregroundMuted
                        font.pixelSize: provider.tokens.fontBody
                    }
                }
            }

            Text {
                visible: provider.expanded && provider.notice.length > 0
                width: parent.width
                wrapMode: Text.WordWrap
                color: provider.tokens.warning
                font.pixelSize: provider.tokens.fontSmall
                text: provider.notice
            }
        }
    }
}
