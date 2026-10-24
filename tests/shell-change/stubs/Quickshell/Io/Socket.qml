import QtQuick

/// Bookkeeping tests do not connect to Core or send data.
QtObject {
    property string path: ""
    property bool connected: false
    property var parser: null
    signal connectionStateChanged()
    function write(data) {}
    function flush() {}
}
