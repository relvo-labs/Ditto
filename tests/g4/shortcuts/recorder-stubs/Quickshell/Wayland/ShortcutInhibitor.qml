import QtQuick
// Offscreen fixture: no compositor, so it never grants inhibition.
QtObject {
    property var window: null
    property bool enabled: false
    property bool active: false
    signal cancelled()
}
