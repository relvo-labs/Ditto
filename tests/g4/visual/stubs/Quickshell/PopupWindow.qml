import QtQuick
import DittoStub

/// Test double for a popup: placed at its anchor rectangle on the window's
/// position.
QtObject {
    id: popup

    property bool visible: false
    property real implicitWidth: 0
    property real implicitHeight: 0
    property color color: "transparent"
    property PopupAnchor anchor: PopupAnchor {}
    readonly property real width: content.width
    readonly property real height: content.height
    default property alias data: content.data

    property Item stubContent: Item {
        id: content
        parent: StubDesktop.layer
        visible: popup.visible
        z: 10
        width: popup.implicitWidth
        height: popup.implicitHeight
        x: (popup.anchor.window && popup.anchor.window.contentItem ? popup.anchor.window.contentItem.x : 0) + popup.anchor.rect.x
        y: (popup.anchor.window && popup.anchor.window.contentItem ? popup.anchor.window.contentItem.y : 0) + popup.anchor.rect.y
    }
}
