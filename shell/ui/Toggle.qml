pragma ComponentBehavior: Bound
import QtQuick

/// An on/off switch with its state also written as text (開／關), so the
/// state never depends on colour alone. With a #116 candidate style the
/// switch is a jelly track with a raised bead; the text stays.
Item {
    id: toggle

    required property var tokens
    property string text: ""
    property bool checked: false
    property string labelOn: "on"
    property string labelOff: "off"
    signal toggled(bool value)

    readonly property bool jelly: tokens.uiCandidate === true

    implicitWidth: row.implicitWidth
    implicitHeight: Math.max(jelly ? tokens.uiControlHeight : tokens.controlHeight, row.implicitHeight)
    activeFocusOnTab: enabled
    opacity: enabled || jelly ? 1 : 0.45
    Accessible.role: Accessible.CheckBox
    Accessible.name: text
    Accessible.checked: checked
    Accessible.onToggleAction: if (enabled) toggled(!checked)
    Keys.onSpacePressed: if (enabled) toggled(!checked)
    Keys.onReturnPressed: if (enabled) toggled(!checked)

    Row {
        id: row
        anchors.verticalCenter: parent.verticalCenter
        spacing: toggle.tokens.space

        Rectangle {
            visible: !toggle.jelly
            width: 38
            height: 20
            radius: 10
            anchors.verticalCenter: parent.verticalCenter
            color: toggle.checked ? toggle.tokens.accent : toggle.tokens.surfaceStrong
            border.color: toggle.activeFocus ? toggle.tokens.focus : toggle.tokens.border
            border.width: toggle.activeFocus ? 2 : 1

            Rectangle {
                width: 14
                height: 14
                radius: 7
                y: 3
                x: toggle.checked ? parent.width - width - 3 : 3
                color: toggle.checked ? toggle.tokens.accentForeground : toggle.tokens.foregroundMuted
                Behavior on x { NumberAnimation { duration: toggle.tokens.durationFast } }
            }
        }

        // ---- #116 candidate switch ----
        Loader {
            active: toggle.jelly
            visible: active
            anchors.verticalCenter: parent.verticalCenter
            sourceComponent: Item {
                objectName: "toggleTrack"
                width: 44
                height: 26

                JellySurface {
                    anchors.fill: parent
                    tokens: toggle.tokens
                    radius: height / 2
                    fill: !toggle.enabled ? toggle.tokens.uiTrack : toggle.checked ? toggle.tokens.uiAccent : toggle.tokens.uiTrack
                    fillTop: toggle.checked && toggle.enabled ? toggle.tokens.uiAccentTop : fill
                    edge: toggle.checked ? "transparent" : toggle.tokens.uiCardBorder
                    raised: false
                    sheen: toggle.checked
                }
                JellySurface {
                    objectName: "toggleKnob"
                    width: 20
                    height: 20
                    y: 3
                    x: toggle.checked ? parent.width - width - 3 : 3
                    tokens: toggle.tokens
                    radius: 10
                    fill: toggle.tokens.uiBead
                    edge: toggle.tokens.uiBeadEdge
                    lift: 0.7
                    Behavior on x { enabled: toggle.tokens.motionEnabled === true; NumberAnimation { duration: toggle.tokens.motionFeedback; easing.type: Easing.OutCubic } }
                }
                Rectangle {
                    anchors.fill: parent
                    anchors.margins: -3
                    radius: height / 2
                    color: "transparent"
                    border.color: toggle.tokens.uiFocus
                    border.width: toggle.activeFocus ? 2 : 0
                }
            }
        }

        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: toggle.text + "  ·  " + (toggle.checked ? toggle.labelOn : toggle.labelOff)
            color: toggle.jelly ? (toggle.enabled ? toggle.tokens.uiInk : toggle.tokens.uiInkDisabled) : toggle.tokens.foreground
            font.pixelSize: toggle.jelly ? toggle.tokens.uiFontLabel : toggle.tokens.fontBody
        }
    }

    MouseArea {
        anchors.fill: parent
        enabled: toggle.enabled
        onClicked: toggle.toggled(!toggle.checked)
    }
}
