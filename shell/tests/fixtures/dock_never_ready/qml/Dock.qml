import QtQuick
import Quickshell

// Failure fixture: loads but never sets ready, so healthy() is never asked
// and the prepare must fail after the 2 s readiness bound.
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
    function healthy() { return true }
    function release() { shown = false }
    PanelWindow {
        visible: provider.shown
        anchors { bottom: true }
        implicitWidth: 300
        implicitHeight: 40
        exclusiveZone: provider.shown ? 40 : 0
        color: "red"
    }
}
