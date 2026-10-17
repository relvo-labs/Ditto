pragma Singleton
import QtQuick

/// Test double: no audio server (the offscreen harness has none).
QtObject {
    property var defaultAudioSink: null
    property bool ready: false
}
