pragma ComponentBehavior: Bound
import QtQuick

/// #116: Ditto's own window buttons, drawn by the Shell for its own windows
/// (centers, chat, approval). Three jelly beads in three lavender shades —
/// minimize, maximize/restore, close, in that order on the right. Their
/// symbols appear while the pointer is over the group or a bead has keyboard
/// focus; close turns soft red then. Each bead is a real button: a text
/// accessible name, Tab to reach, Enter/Space to press, a 28 px hit target.
/// The caller gives the (translated) names and decides what each does.
Row {
    id: controls

    required property var tokens
    property bool showMinimize: true
    property bool showMaximize: true
    property bool maximized: false
    property string minimizeText: ""
    property string maximizeText: ""
    property string restoreText: ""
    property string closeText: ""
    signal minimizeRequested()
    signal maximizeRequested()
    signal closeRequested()

    spacing: 2

    HoverHandler { id: groupHover }

    // An inline component does not see this file's ids: everything it
    // needs comes in through properties.
    component Bead: Item {
        id: bead
        required property var tokens
        property bool maximized: false
        property bool groupHovered: false
        property string kind: "close"
        property color shade: tokens.uiBeadClose
        property string name: ""
        signal pressed()
        readonly property bool reveal: groupHovered || bead.activeFocus
        readonly property bool hot: kind === "close" && (beadArea.containsMouse || bead.activeFocus)
        width: 28
        height: 28
        activeFocusOnTab: true
        Accessible.role: Accessible.Button
        Accessible.name: name
        Accessible.onPressAction: bead.pressed()
        Keys.onReturnPressed: bead.pressed()
        Keys.onEnterPressed: bead.pressed()
        Keys.onSpacePressed: bead.pressed()

        JellySurface {
            id: face
            objectName: "beadFace"
            anchors.centerIn: parent
            width: 16
            height: 16
            tokens: bead.tokens
            radius: 8
            // J3: a bubble (translucent, coloured rim); J1/J2: a filled bead.
            readonly property bool bubble: bead.tokens.uiJ3 === true && !bead.hot && !bead.reveal
            fill: bead.hot ? bead.tokens.uiBeadCloseHot : bubble ? bead.tokens.uiFill("#ffffff", 0.35) : bead.shade
            fillTop: Qt.lighter(fill, 1.12)
            edge: bubble ? Qt.darker(bead.shade, 1.15) : Qt.darker(fill, 1.12)
            edgeWidth: bubble ? 2 : 1
            lift: beadArea.pressed ? 0.2 : 0.5
            sheen: true
            transform: Scale {
                origin.x: 8; origin.y: 16
                xScale: beadArea.pressed && bead.tokens.motionEnabled === true ? bead.tokens.uiPressScaleX : 1
                yScale: beadArea.pressed && bead.tokens.motionEnabled ? bead.tokens.uiPressScaleY : 1
            }
        }

        Item {
            objectName: "beadGlyph"
            visible: bead.reveal
            anchors.centerIn: face
            width: 8
            height: 8

            // minimize: a bar
            Rectangle {
                visible: bead.kind === "minimize"
                anchors.centerIn: parent
                width: 8; height: 1.6; radius: 0.8
                color: bead.tokens.uiBeadGlyph
            }
            // maximize: a ring; restore: two overlapping rings
            Rectangle {
                visible: bead.kind === "maximize"
                x: bead.maximized ? 2 : 0.5
                y: bead.maximized ? 0 : 0.5
                width: bead.maximized ? 6 : 7
                height: width
                radius: 1.5
                color: "transparent"
                border.color: bead.tokens.uiBeadGlyph
                border.width: 1.4
            }
            Rectangle {
                visible: bead.kind === "maximize" && bead.maximized
                x: 0; y: 2
                width: 6; height: 6; radius: 1.5
                color: bead.shade
                border.color: bead.tokens.uiBeadGlyph
                border.width: 1.4
            }
            // close: a cross
            Repeater {
                model: bead.kind === "close" ? [45, -45] : []
                Rectangle {
                    required property real modelData
                    anchors.centerIn: parent
                    width: 9; height: 1.6; radius: 0.8
                    rotation: modelData
                    color: bead.tokens.uiBeadGlyph
                }
            }
        }

        Rectangle {
            anchors.centerIn: face
            width: 22
            height: 22
            radius: 11
            color: "transparent"
            border.color: bead.tokens.uiFocus
            border.width: bead.activeFocus ? 2 : 0
        }

        MouseArea {
            id: beadArea
            anchors.fill: parent
            hoverEnabled: true
            onClicked: bead.pressed()
        }
    }

    Bead {
        objectName: "windowMinimize"
        tokens: controls.tokens
        maximized: controls.maximized
        groupHovered: groupHover.hovered
        visible: controls.showMinimize
        kind: "minimize"
        shade: controls.tokens.uiBeadMinimize
        name: controls.minimizeText
        onPressed: controls.minimizeRequested()
    }
    Bead {
        objectName: "windowMaximize"
        tokens: controls.tokens
        maximized: controls.maximized
        groupHovered: groupHover.hovered
        visible: controls.showMaximize
        kind: "maximize"
        shade: controls.tokens.uiBeadMaximize
        name: controls.maximized ? controls.restoreText : controls.maximizeText
        onPressed: controls.maximizeRequested()
    }
    Bead {
        objectName: "windowClose"
        tokens: controls.tokens
        maximized: controls.maximized
        groupHovered: groupHover.hovered
        kind: "close"
        shade: controls.tokens.uiBeadClose
        name: controls.closeText
        onPressed: controls.closeRequested()
    }
}
