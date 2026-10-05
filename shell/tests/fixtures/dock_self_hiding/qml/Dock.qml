import QtQuick
import Quickshell

// Readback fixture: prepares and commits normally, then hides itself right
// after it is shown. The Shell reports what it observes (visible: false), so
// Core's readback disagrees with the target and the change must be rolled
// back to the previous dock — the same retired instance, not a new one.
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
    Component.onCompleted: ready = true
    onShownChanged: if (shown) Qt.callLater(() => provider.shown = false)
    PanelWindow {
        visible: provider.shown
        anchors { bottom: true }
        implicitWidth: 300
        implicitHeight: 40
        exclusiveZone: provider.shown ? 40 : 0
        color: "gray"
    }
}
