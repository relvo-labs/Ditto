import QtQuick

// D-34 simple status provider for the `ui.status_item` slot. The provider
// interface (client, ready, healthy(), release()) is defined by the Shell
// workstream (plan/03/04 §2.1); this file only follows its shape.
Item {
    id: root
    property var client: null
    property bool ready: true
    property date now: new Date()
    implicitWidth: label.implicitWidth
    implicitHeight: label.implicitHeight

    function healthy() { return ready }
    function release() { }

    Text {
        id: label
        text: Qt.formatDate(now, Qt.locale().dateFormat(Locale.ShortFormat))
        Accessible.name: qsTr("日期")
    }

    // A minute-resolution clock; stops when hidden so it costs nothing off screen.
    Timer {
        interval: 60000
        running: root.visible
        repeat: true
        onTriggered: root.now = new Date()
    }
}
