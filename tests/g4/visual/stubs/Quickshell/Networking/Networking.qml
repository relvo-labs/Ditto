pragma Singleton
import QtQuick

/// Test double: no network manager (the offscreen harness has none).
QtObject {
    property var devices: null
    property int backend: NetworkBackendType.None
    property int connectivity: NetworkConnectivity.Unknown
}
