import QtQuick

// D-34 simple status item for the `ui.status_item` area: any number of them
// are mounted side by side in the top panel's status region (or the Shell's
// status strip), in Profile order. It follows the Shell's provider interface
// (plan/03/04 §2.1): the host sets client, tokens, config, screen, slotName,
// entryId and shown; the item declares ready, healthy() and release().
// Trusted QML in the Shell process (same host, no isolation).
Item {
    id: root
    property var client: null
    property var tokens: null
    property var config: ({})
    property var screen: null
    property string slotName: ""
    property string entryId: ""
    property bool shown: false
    property bool ready: true
    property int value: 0  // fed from a Core snapshot by the Shell, not polled here
    visible: shown
    implicitWidth: label.implicitWidth
    implicitHeight: label.implicitHeight

    function healthy() { return ready }
    function release() { shown = false }

    Text {
        id: label
        text: qsTr("電池 %1%").arg(value)
        color: root.tokens ? root.tokens.foreground : "white"
        font.pixelSize: root.tokens ? root.tokens.fontSmall : 12
        Accessible.name: qsTr("電池電量")
    }
}
