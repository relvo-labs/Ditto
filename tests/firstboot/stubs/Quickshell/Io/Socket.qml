import QtQuick
// Transport double: never opens a socket. Production framing/API is linted
// against the installed Quickshell 0.3.1 metadata, not this double.
QtObject {
    property bool connected: false
    property string path: ""
    property var parser: null
    property string sent: ""
    signal connectionStateChanged()
    signal error()
    onConnectedChanged: connectionStateChanged()
    function write(data) { sent += data; }
    function flush() {}
}
