pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// The future capability proxy supplies availability and handles this signal
// through Core authorization. No arbitrary command or direct RPC is accepted.
Item {
    id: root
    property var client: null
    property var screen: null
    property string reservedEdge: "none"
    property var config: ({})
    property var availableWorkspaceIds: []
    property bool actionsAvailable: false
    property bool testData: false
    property bool ready: false
    signal activateWorkspaceRequested(string workspaceId)
    implicitWidth: config.width || 280
    implicitHeight: body.implicitHeight + 32
    function healthy() { return ready }
    function release() { ready = false }
    Component.onCompleted: ready = true

    Rectangle {
        anchors.fill: parent
        radius: 16
        color: "#F5F0FF"
        border.color: root.config.accent || "#8B5CF6"
    }
    ColumnLayout {
        id: body
        anchors { left: parent.left; right: parent.right; top: parent.top; margins: 16 }
        spacing: 8
        Text {
            objectName: "panelTitle"
            text: root.config.title || qsTr("工作區捷徑")
            textFormat: Text.PlainText
            color: "#241B35"
            font.bold: true
            wrapMode: Text.Wrap
            Layout.fillWidth: true
            Accessible.role: Accessible.Heading
            Accessible.name: text
        }
        Text {
            objectName: "testDataLabel"
            visible: root.testData
            text: qsTr("預覽使用測試資料")
            textFormat: Text.PlainText
            color: "#504060"
            wrapMode: Text.Wrap
            Layout.fillWidth: true
        }
        Text {
            visible: !root.actionsAvailable
            text: qsTr("工作區操作目前不可用")
            textFormat: Text.PlainText
            color: "#504060"
        }
        Repeater {
            model: (root.config.content || {}).actions || []
            Button {
                id: actionButton
                required property var modelData
                objectName: "workspaceAction_" + modelData.workspace_id
                enabled: root.actionsAvailable && root.availableWorkspaceIds.indexOf(modelData.workspace_id) >= 0
                Layout.fillWidth: true
                Accessible.name: modelData.label
                contentItem: Text {
                    text: actionButton.modelData.label
                    textFormat: Text.PlainText
                    color: actionButton.enabled ? "#241B35" : "#756A80"
                    horizontalAlignment: Text.AlignHCenter
                    elide: Text.ElideRight
                }
                onClicked: root.activateWorkspaceRequested(modelData.workspace_id)
            }
        }
    }
}
