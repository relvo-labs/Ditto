pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts

// Trusted fixed template. Generated text is DATA, never QML source.
// Core capability projection and ProviderHost mounting are not wired yet.
Item {
    id: root
    property var client: null
    property var screen: null
    property string reservedEdge: "none"
    property var config: ({})
    property var tasks: []
    property bool testData: false
    property bool dataAvailable: false
    property bool ready: false
    readonly property var displayedTasks: {
        const content = config.content || {}
        let result = tasks.filter(t => content.show_completed || !t.done)
        if (content.order === "title") result = result.slice().sort((a, b) => a.text.localeCompare(b.text))
        return result.slice(0, content.max_items || 5)
    }
    implicitWidth: config.width || 320
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
            text: root.config.title || qsTr("待辦摘要")
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
            Layout.fillWidth: true
            wrapMode: Text.Wrap
        }
        Text {
            objectName: "dataStatus"
            visible: !root.dataAvailable || root.displayedTasks.length === 0
            text: root.dataAvailable ? qsTr("沒有符合條件的待辦") : qsTr("尚未取得待辦資料")
            textFormat: Text.PlainText
            color: "#504060"
        }
        Repeater {
            model: root.dataAvailable ? root.displayedTasks : []
            Text {
                required property var modelData
                text: (modelData.done ? "✓ " : "○ ") + modelData.text
                textFormat: Text.PlainText
                wrapMode: Text.Wrap
                color: "#241B35"
                Layout.fillWidth: true
                Accessible.role: Accessible.StaticText
                Accessible.name: text
            }
        }
    }
}
