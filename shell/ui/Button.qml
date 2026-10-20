pragma ComponentBehavior: Bound
import QtQuick

/// A button of the Shell's own surfaces. Keyboard: Tab to reach, Enter or
/// Space to press; focus is drawn as a ring, not only as a colour change.
///
/// With a #116 candidate style (`tokens.uiCandidate`) the same button draws a
/// jelly face instead: primary (filled), secondary (tonal), subtle (ghost),
/// danger (solid, for a confirmation) and dangerQuiet (a destructive action
/// that is not yet confirmed). Pressing squashes the face, never the hit
/// target. Without a style nothing here changes.
Rectangle {
    id: button

    required property var tokens
    property string text: ""
    /// primary | secondary | subtle | danger (| dangerQuiet with a candidate style)
    property string kind: "secondary"
    property string accessibleName: text
    /// Candidate style only: a pick that stays chosen (e.g. a diff's start)
    /// is drawn as a selected bead with a marker, never as a primary action.
    property bool checked: false
    /// Styled face only: the side padding (a dense toolbar may use less).
    property int jellyPad: tokens.uiPadCard
    signal clicked()

    readonly property bool jelly: tokens.uiCandidate === true

    implicitWidth: jelly ? Math.max(tokens.uiControlHeight, jellyLabel.implicitWidth + jellyPad * 2 + (checked ? 14 : 0))
        : label.implicitWidth + tokens.spaceWide * 2
    implicitHeight: jelly ? tokens.uiControlHeight : tokens.controlHeight
    radius: tokens.radiusSmall
    opacity: enabled || jelly ? 1.0 : 0.45
    color: jelly ? "transparent"
        : kind === "primary" ? tokens.accent
        : kind === "danger" ? tokens.danger
        : kind === "subtle" ? (area.containsMouse ? tokens.surface : "transparent")
        : (area.containsMouse ? tokens.surface : tokens.surfaceStrong)
    border.color: jelly || kind === "subtle" ? "transparent" : tokens.border
    border.width: 1
    activeFocusOnTab: enabled
    Accessible.role: Accessible.Button
    Accessible.name: accessibleName
    Accessible.checkable: jelly && checked
    Accessible.checked: jelly && checked
    Accessible.onPressAction: if (enabled) clicked()

    Keys.onReturnPressed: if (enabled) clicked()
    Keys.onEnterPressed: if (enabled) clicked()
    Keys.onSpacePressed: if (enabled) clicked()

    Text {
        id: label
        visible: !button.jelly
        anchors.centerIn: parent
        text: button.text
        color: button.kind === "primary" ? button.tokens.accentForeground
            : button.kind === "danger" ? button.tokens.statusForeground : button.tokens.foreground
        font.pixelSize: button.tokens.fontBody

        // The `font_family` token, when the Profile sets one; the system
        // font otherwise.
        Binding on font.family {
            when: button.tokens.fontFamily.length > 0
            value: button.tokens.fontFamily
        }
    }

    Rectangle {
        anchors.fill: parent
        anchors.margins: -3
        radius: parent.radius + 3
        color: "transparent"
        border.color: button.tokens.focus
        border.width: button.activeFocus && !button.jelly ? 2 : 0
    }

    // ---- #116 candidate face ------------------------------------------------------
    Item {
        id: face
        objectName: "buttonFace"
        visible: button.jelly
        anchors.fill: parent

        readonly property bool picked: button.checked
        readonly property bool solid: !picked && (button.kind === "primary" || button.kind === "danger")
        readonly property bool ghost: button.kind === "subtle"
        readonly property real faceRadius: button.tokens.uiJ1 ? button.tokens.uiRadiusControl : height / 2
        readonly property color fillColor: picked ? button.tokens.uiSelectFill
            : !button.enabled ? (ghost ? "transparent" : button.tokens.uiTrack)
            : button.kind === "primary" ? button.tokens.uiAccent
            : button.kind === "danger" ? button.tokens.uiDangerSolid
            : button.kind === "dangerQuiet" ? button.tokens.uiDangerFill
            : ghost ? (area.containsMouse ? button.tokens.uiGhostHover : "transparent")
            : (area.containsMouse ? button.tokens.uiTonalHover : button.tokens.uiTonal)
        readonly property color inkColor: !button.enabled ? button.tokens.uiInkDisabled
            : picked ? button.tokens.uiInk
            : solid ? button.tokens.uiOnAccent
            : button.kind === "dangerQuiet" ? button.tokens.uiDanger
            : ghost ? button.tokens.uiAccentInk : button.tokens.uiInk

        // Press squash: the face only; hit target and layout stay put.
        readonly property bool motion: button.jelly && button.tokens.motionEnabled === true
        readonly property real targetX: motion && area.pressed && button.enabled ? button.tokens.uiPressScaleX : 1
        readonly property real targetY: motion && area.pressed && button.enabled ? button.tokens.uiPressScaleY : 1
        property real squashX: 1
        property real squashY: 1
        readonly property bool squashAnimating: squashXAnimation.running || squashYAnimation.running
        function retarget() {
            squashXAnimation.stop();
            squashYAnimation.stop();
            if (!motion) {
                squashX = targetX;
                squashY = targetY;
                return;
            }
            squashXAnimation.from = squashX;
            squashXAnimation.to = targetX;
            squashYAnimation.from = squashY;
            squashYAnimation.to = targetY;
            squashXAnimation.start();
            squashYAnimation.start();
        }
        onTargetXChanged: retarget()
        onTargetYChanged: retarget()
        onMotionChanged: if (!motion) retarget()
        NumberAnimation {
            id: squashXAnimation
            target: face; property: "squashX"
            duration: button.tokens.motionFeedback
            easing.type: Easing.OutCubic
        }
        NumberAnimation {
            id: squashYAnimation
            target: face; property: "squashY"
            duration: button.tokens.motionFeedback
            easing.type: Easing.OutCubic
        }

        Item {
            id: body
            anchors.fill: parent
            transform: Scale {
                origin.x: body.width / 2
                origin.y: body.height
                xScale: face.squashX
                yScale: face.squashY
            }

            Loader {
                anchors.fill: parent
                active: button.jelly
                sourceComponent: JellySurface {
                tokens: button.tokens
                radius: face.faceRadius
                fill: face.fillColor
                fillTop: button.enabled && button.kind === "primary" ? button.tokens.uiAccentTop
                    : button.enabled && button.kind === "danger" ? Qt.lighter(button.tokens.uiDangerSolid, 1.12) : face.fillColor
                edge: face.picked ? button.tokens.uiBeadEdge
                    : face.ghost || !button.enabled ? "transparent"
                    : face.solid ? Qt.darker(face.fillColor, 1.08) : button.tokens.uiCardBorder
                raised: button.enabled && (face.picked || !face.ghost && (face.solid || button.tokens.uiJ2))
                lift: area.pressed ? 0.35 : (face.solid ? 0.8 : 0.5)
                sheen: button.enabled && !face.ghost
                lipColor: button.kind === "primary" ? button.tokens.uiAccentLip
                    : button.kind === "danger" ? Qt.darker(button.tokens.uiDangerSolid, 1.3) : button.tokens.uiLip
                lip: !area.pressed && button.enabled && !face.ghost && button.tokens.uiJ2 === true
                iris: button.tokens.uiJ3 === true && !face.solid && !face.ghost
                }
            }

            /// Pressed shade: the press feedback that remains with reduced
            /// motion or the low-power style, where the face does not squash.
            Rectangle {
                visible: area.pressed && button.enabled
                anchors.fill: parent
                radius: face.faceRadius
                color: Qt.rgba(0.14, 0.10, 0.30, 0.08)
            }

            /// Hover glow on solid fills.
            Rectangle {
                visible: face.solid && button.enabled && area.containsMouse && !area.pressed
                anchors.fill: parent
                radius: face.faceRadius
                color: Qt.rgba(1, 1, 1, 0.14)
            }

            Rectangle {
                visible: face.picked
                width: 7; height: 7; radius: 3.5
                x: button.jellyPad - 4
                anchors.verticalCenter: parent.verticalCenter
                color: button.tokens.uiSelectDot
            }

            Text {
                id: jellyLabel
                anchors.centerIn: parent
                anchors.horizontalCenterOffset: face.picked ? 7 : 0
                text: button.text
                color: face.inkColor
                font.pixelSize: button.tokens.uiFontBody
                font.weight: face.solid || face.picked ? Font.DemiBold : Font.Medium
                Binding on font.family {
                    when: button.tokens.fontFamily.length > 0
                    value: button.tokens.fontFamily
                }
            }
        }

        Rectangle {
            anchors.fill: parent
            anchors.margins: -3
            radius: face.faceRadius + 3
            color: "transparent"
            border.color: button.tokens.uiFocus
            border.width: button.activeFocus ? 2 : 0
        }
    }

    MouseArea {
        id: area
        anchors.fill: parent
        hoverEnabled: true
        enabled: button.enabled
        cursorShape: Qt.PointingHandCursor
        onClicked: button.clicked()
    }
}
