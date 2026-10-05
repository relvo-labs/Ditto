import QtQuick
import Quickshell

// Timing fixture: healthy, but becomes ready only after 1.5 s, which holds
// the prepare open long enough to kill the Shell in the middle of it
// (plan/03/04 §11 #3). Nothing in the Shell itself waits on purpose.
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
    Timer { running: true; interval: 1500; onTriggered: provider.ready = true }
    PanelWindow {
        visible: provider.shown
        anchors { bottom: true }
        implicitWidth: 300
        implicitHeight: 40
        exclusiveZone: provider.shown ? 40 : 0
        color: provider.tokens ? provider.tokens.surfaceStrong : "gray"
    }
}
