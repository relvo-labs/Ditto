import QtQuick
QtObject {
    property bool running: false
    property var command: []
    property var stdout: null
    property int starts: 0
    onRunningChanged: if (running) ++starts
}
