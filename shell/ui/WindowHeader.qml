import QtQuick

/// #116: the single title row of a Ditto window with a candidate style: the
/// window's one visible title on the left, optional `tools` in the middle,
/// and WindowControls on the right. Dragging the row moves the window and a
/// double click maximizes or restores it, through the window's own
/// `startSystemMove()` / `maximized` / `minimized` (of `hostWindow`) when it has them (a
/// Quickshell FloatingWindow does; an offscreen double does not, and then the
/// row is only drawn).
///
/// `frameless` asks Qt not to draw its own title bar for this window (Qt's
/// FramelessWindowHint), so the title appears once. It is applied only to a
/// real window and only while a style is on (the header exists only then),
/// and undone when the header goes; whether the compositor and Qt honour it
/// on the target session is checked there.
Item {
    id: header

    required property var tokens
    property string title: ""
    /// The FloatingWindow this header belongs to (or null). Not named
    /// `window`: a caller's `window: window` would bind to this property.
    property var hostWindow: null
    property bool showMinimize: true
    property bool showMaximize: true
    property bool frameless: true
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

    /// The window this header made frameless, or null. Only a hint the
    /// header added is taken away again (when the header goes: the style is
    /// turned off, the theme changes, an undo), so the window gets its
    /// native title bar back and keeps every flag it had before.
    property var framelessWindow: null
    function applyFrameless() {
        const backing = header.Window.window;
        if (framelessWindow && framelessWindow !== backing) restoreFrameless();
        if (!frameless || !canMove || !backing || backing.flags === undefined) return;
        if (!(backing.flags & Qt.FramelessWindowHint)) {
            backing.flags = backing.flags | Qt.FramelessWindowHint;
            framelessWindow = backing;
        }
    }
    function restoreFrameless() {
        const backing = framelessWindow;
        framelessWindow = null;
        if (backing && backing.flags !== undefined) backing.flags = backing.flags & ~Qt.FramelessWindowHint;
    }
    Component.onCompleted: applyFrameless()
    Component.onDestruction: restoreFrameless()
    onHostWindowChanged: applyFrameless()
    onFramelessChanged: frameless ? applyFrameless() : restoreFrameless()
    Connections {
        target: header.Window
        function onWindowChanged() { header.applyFrameless(); }
    }

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
