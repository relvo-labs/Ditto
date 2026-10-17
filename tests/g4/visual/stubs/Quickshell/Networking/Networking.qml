pragma Singleton
import QtQuick

/// Test double: no network manager (the offscreen harness has none).
QtObject {
    property var devices: null
}
