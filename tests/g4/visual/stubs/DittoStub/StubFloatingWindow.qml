import QtQuick

/// Test double for Quickshell 0.3.1's FloatingWindow (src/window/proxywindow.cpp
/// at 1a4716c) with a real offscreen backing window, so that a test can see
/// when the backing window's flags change (unit/tst_ui_style_frameless.qml).
/// Not part of the product. What is modelled:
/// - the window's items sit in `contentItem`, which joins the backing window
///   one event-loop turn after creation (Reloadable::componentComplete →
///   onReload → completeWindow) and before the window is first shown
///   (postCompleteWindow → setVisible);
/// - `visible` on this object shows or hides the backing window and is not a
///   close; the backing window disappearing while `visible` is still true is
///   (ProxyWindowBase::onVisibleChanged emits `closed`);
/// - every change of the backing window's flags is recorded with whether the
///   window was shown at that moment (`flagWrites`), and every time it is
///   shown is counted (`maps`).
/// Not modelled: Wayland surfaces, Qt's own title bar, the render thread.
QtObject {
    id: proxy

    default property alias data: content.data
    readonly property Item contentItem: Item {
        id: content
        width: backing.width
        height: backing.height
    }
    readonly property Window backingWindow: Window {
        id: backing
        width: Math.max(1, proxy.implicitWidth)
        height: Math.max(1, proxy.implicitHeight)
        flags: proxy.initialFlags
        color: proxy.color
        title: proxy.title
        visible: false
        onFlagsChanged: proxy.flagWrites.push({ flags: backing.flags, shown: backing.visible })
        onVisibleChanged: {
            if (backing.visible) {
                proxy.maps++;
            } else if (proxy.connected && proxy.visible) {
                proxy.visible = false;
                proxy.closed();
            }
        }
    }

    /// The backing window's flags before anything in the window changes them.
    property int initialFlags: Qt.Window
    property bool connected: false
    property var flagWrites: []
    property int maps: 0

    property string title: ""
    property size minimumSize: Qt.size(0, 0)
    property var screen: null
    property real implicitWidth: 0
    property real implicitHeight: 0
    readonly property real width: backing.width
    readonly property real height: backing.height
    property color color: "white"
    property bool visible: false
    property bool maximized: false
    property bool minimized: false
    signal closed()
    function startSystemMove() {}

    Component.onCompleted: Qt.callLater(proxy.connectWindow)
    function connectWindow() {
        content.parent = backing.contentItem;
        connected = true;
        backing.visible = proxy.visible;
    }
    onVisibleChanged: if (connected) backing.visible = proxy.visible
}
