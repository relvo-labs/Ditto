import QtQuick
import Quickshell

// Failure fixture (plan/03/04 §11 #2): this file does not parse, so the
// candidate never loads and the change must abort with the active dock intact.
Scope {
    property var client: null
    property var tokens: null
    property bool shown: false
    property bool ready: true
    function healthy() { return true }
    function release() { shown = false }
    PanelWindow {
        visible: shown
        anchors { bottom: true
        implicitHeight: 40
    }
