import QtQuick

// QML provider template for the `ui.dock` slot. The slot interface is owned by
// the Shell workstream (plan/03/04 §2.1): `client`, `screen`, `reservedEdge`,
// `ready`, `healthy()`, `release()`. ProviderHost mounts this file as a hidden
// candidate, calls healthy(), and only after the active provider's release()
// returns may this one take the exclusive zone. Keep animation local to QML;
// never drive frames through the Core connection.
Item {
    id: root

    // Set by ProviderHost.
    property var client: null
    property var screen: null
    property string reservedEdge: "bottom"
    property var config: ({})

    // True once this provider can be shown. ProviderHost waits for it.
    property bool ready: false

    function healthy() {
        return ready
    }

    // Give back the layer-shell surface, exclusive zone and input region.
    function release() {
        ready = false
    }

    implicitHeight: (config.icon_size || 40) + 16

    Rectangle {
        anchors.fill: parent
        radius: height / 2
        color: palette.window
        Accessible.role: Accessible.ToolBar
        Accessible.name: qsTr("工作列")
    }

    Component.onCompleted: ready = true
}
