import QtQuick
import Quickshell

// Failure fixture: loads and becomes ready, but healthy() answers false.
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
    function healthy() { return false }
    function release() { shown = false }
    Component.onCompleted: ready = true
    PanelWindow {
        visible: provider.shown
        anchors { bottom: true }
        implicitWidth: 300
        implicitHeight: 40
        exclusiveZone: provider.shown ? 40 : 0
        color: "red"
    }
}
