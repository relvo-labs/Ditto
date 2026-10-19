import QtQuick

/// #116: the single title row of a Ditto window with a candidate style: the
/// window's one visible title on the left, optional `tools` in the middle,
/// and WindowControls on the right. Dragging the row moves the window and a
/// double click maximizes or restores it, through the window's own
/// `startSystemMove()` / `maximized` / `minimized` when it has them (a
/// Quickshell FloatingWindow does; an offscreen double does not, and then the
/// row is only drawn).
///
/// `frameless` asks Qt not to draw its own title bar for this window (Qt's
/// FramelessWindowHint), so the title appears once. It is applied only to a
/// real window and only while a candidate style is on; whether the
/// compositor and Qt honour it on the target session is checked there.
Item {
    id: header

    required property var tokens
    property string title: ""
    /// The FloatingWindow this header belongs to (or null).
    property var window: null
    property bool showMinimize: true
    property bool showMaximize: true
    property bool frameless: true
    property string minimizeText: ""
    property string maximizeText: ""
    property string restoreText: ""
    property string closeText: ""
    default property alias tools: toolRow.data
    signal closeRequested()

    readonly property bool canMove: !!window && typeof window.startSystemMove === "function"
    readonly property bool maximized: !!window && window.maximized === true

    implicitHeight: tokens.uiHeaderHeight
    height: implicitHeight

    function applyFrameless() {
        const backing = header.Window.window;
        if (!frameless || !canMove || !backing || backing.flags === undefined) return;
        if (!(backing.flags & Qt.FramelessWindowHint)) backing.flags = backing.flags | Qt.FramelessWindowHint;
    }
    Component.onCompleted: applyFrameless()
    Connections {
        target: header.Window
        function onWindowChanged() { header.applyFrameless(); }
    }

    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton
        onPressed: if (header.canMove) header.window.startSystemMove()
        onDoubleClicked: if (header.canMove && header.showMaximize) header.window.maximized = !header.window.maximized
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
        onMinimizeRequested: if (header.window) header.window.minimized = true
        onMaximizeRequested: if (header.window) header.window.maximized = !header.window.maximized
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
