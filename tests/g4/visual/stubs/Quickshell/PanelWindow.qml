import QtQuick
import DittoStub

/// Test double for a layer-shell PanelWindow: its content is an Item on
/// `StubDesktop.layer`, sized and placed by the layer-shell rules (anchored
/// on both opposite edges → stretched; on one → against it with its margin;
/// on neither → centred). Exclusive zones, keyboard focus and input regions
/// are recorded, not enforced.
QtObject {
    id: window

    property var screen: null
    property bool visible: true
    property real implicitWidth: 0
    property real implicitHeight: 0
    property int exclusiveZone: 0
    property int exclusionMode: 0
    property bool aboveWindows: true
    property bool focusable: false
    property color color: "transparent"
    property var mask: null
    property PanelAnchors anchors: PanelAnchors {}
    property PanelMargins margins: PanelMargins {}
    readonly property real width: content.width
    readonly property real height: content.height
    readonly property Item contentItem: content
    default property alias data: content.data

    property Item stubContent: Item {
        id: content
        objectName: "stubPanelWindow"
        parent: StubDesktop.layer
        visible: window.visible
        width: window.anchors.left && window.anchors.right
            ? StubDesktop.screenWidth - window.margins.left - window.margins.right : window.implicitWidth
        height: window.anchors.top && window.anchors.bottom
            ? StubDesktop.screenHeight - window.margins.top - window.margins.bottom : window.implicitHeight
        x: window.anchors.left ? window.margins.left
            : window.anchors.right ? StubDesktop.screenWidth - width - window.margins.right
            : Math.round((StubDesktop.screenWidth - width) / 2)
        y: window.anchors.top ? window.margins.top
            : window.anchors.bottom ? StubDesktop.screenHeight - height - window.margins.bottom
            : Math.round((StubDesktop.screenHeight - height) / 2)

        Rectangle {
            anchors.fill: parent
            z: -1
            color: window.color
        }
    }
}
