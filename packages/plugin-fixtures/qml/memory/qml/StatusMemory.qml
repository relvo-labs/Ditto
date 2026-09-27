import QtQuick

// D-34 simple status provider for the `ui.status_item` slot. The provider
// interface (client, ready, healthy(), release()) is defined by the Shell
// workstream (plan/03/04 §2.1); this file only follows its shape.
Item {
    id: root
    property var client: null
    property bool ready: true
    property int value: 0  // fed from a Core snapshot by the Shell, not polled here
    implicitWidth: label.implicitWidth
    implicitHeight: label.implicitHeight

    function healthy() { return ready }
    function release() { }

    Text {
        id: label
        text: qsTr("記憶體 %1%").arg(value)
        Accessible.name: qsTr("記憶體使用量")
    }

}
