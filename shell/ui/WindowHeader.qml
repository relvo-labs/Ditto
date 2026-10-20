import QtQuick

/// #116: the single title row of a Ditto window with a candidate style: the
/// window's one visible title on the left, optional `tools` in the middle,
/// and WindowControls on the right. Dragging the row moves the window and a
/// double click maximizes or restores it, through the window's own
/// `startSystemMove()` / `maximized` / `minimized` (of `hostWindow`) when it has them (a
/// Quickshell FloatingWindow does; an offscreen double does not, and then the
/// row is only drawn).
///
/// This header never changes its window's flags. Qt not drawing its own
/// title bar (FramelessWindowHint) is the window's WindowFrameless, which
/// changes it only while the window is not shown. Changing it on a shown
/// window crashed the Shell (VM, 2026-10-20 13:03 UTC, Qt 6.10.2, wayland-egl):
/// `QWaylandWindow::setWindowFlags` creates or drops Qt's title bar on the
/// GUI thread at once, while the render thread checks `decoration()` twice
/// per frame. `makeCurrent → bindContentFBO` makes the content buffer only if
/// there is a title bar; `swapBuffers` blits the title bar, reading that
/// buffer's texture, whenever there is one. A title bar that appears between
/// the two is blitted from a buffer that was never made (segfault in
/// `QOpenGLFramebufferObject::texture()` under `DecorationsBlitter::blit`).
/// The header comes and goes with the style (Loader `active: jelly`), so it
/// must not own anything that cannot change while the window is shown.
Item {
    id: header

    required property var tokens
    property string title: ""
    /// The FloatingWindow this header belongs to (or null). Not named
    /// `window`: a caller's `window: window` would bind to this property.
    property var hostWindow: null
    property bool showMinimize: true
    property bool showMaximize: true
    property string minimizeText: ""
    property string maximizeText: ""
    property string restoreText: ""
    property string closeText: ""
    default property alias tools: toolRow.data
    signal closeRequested()

    readonly property bool canMove: !!hostWindow && typeof hostWindow.startSystemMove === "function"
    readonly property bool maximized: !!hostWindow && hostWindow.maximized === true

    implicitHeight: tokens.uiHeaderHeight
    height: implicitHeight

    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton
        onPressed: if (header.canMove) header.hostWindow.startSystemMove()
        onDoubleClicked: if (header.canMove && header.showMaximize) header.hostWindow.maximized = !header.hostWindow.maximized
    }

    Text {
        id: titleText
        anchors.left: parent.left
        anchors.leftMargin: header.tokens.uiPadCard + 4
        anchors.verticalCenter: parent.verticalCenter
        width: Math.min(implicitWidth, toolRow.x - x - header.tokens.uiGap)
        elide: Text.ElideRight
        text: header.title
        color: header.tokens.uiInk
        font.pixelSize: header.tokens.uiFontCardTitle
        font.weight: Font.DemiBold
        Accessible.role: Accessible.TitleBar
        Accessible.name: text
    }

    Row {
        id: toolRow
        anchors.right: controls.left
        anchors.rightMargin: header.tokens.uiGap * 2
        anchors.verticalCenter: parent.verticalCenter
        spacing: header.tokens.uiGap
    }

    WindowControls {
        id: controls
        anchors.right: parent.right
        anchors.rightMargin: header.tokens.uiGap * 1.5
        anchors.verticalCenter: parent.verticalCenter
        tokens: header.tokens
        showMinimize: header.showMinimize
        showMaximize: header.showMaximize
        maximized: header.maximized
        minimizeText: header.minimizeText
        maximizeText: header.maximizeText
        restoreText: header.restoreText
        closeText: header.closeText
        onMinimizeRequested: if (header.hostWindow) header.hostWindow.minimized = true
        onMaximizeRequested: if (header.hostWindow) header.hostWindow.maximized = !header.hostWindow.maximized
        onCloseRequested: header.closeRequested()
    }

    /// A water-line under the header.
    Rectangle {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.leftMargin: header.tokens.uiPadCard
        anchors.rightMargin: header.tokens.uiPadCard
        height: 1
        gradient: Gradient {
            orientation: Gradient.Horizontal
            GradientStop { position: 0.0; color: "transparent" }
            GradientStop { position: 0.2; color: header.tokens.uiSeparator }
            GradientStop { position: 0.8; color: header.tokens.uiSeparator }
            GradientStop { position: 1.0; color: "transparent" }
        }
    }
}
