import QtQuick
Item {
    required property var client
    required property var tokens
    required property var config
    required property string pageId
    required property string entryId
    Component.onCompleted: client.pageCreations += 1
    Component.onDestruction: client.pageDestructions += 1
}
