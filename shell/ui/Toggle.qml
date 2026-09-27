import QtQuick

/// An on/off switch with its state also written as text (開／關), so the
/// state never depends on colour alone.
Item {
    id: toggle

    required property var tokens
    property string text: ""
    property bool checked: false
    property string labelOn: "on"
    property string labelOff: "off"
    signal toggled(bool value)

    implicitWidth: row.implicitWidth
    implicitHeight: Math.max(tokens.controlHeight, row.implicitHeight)
    activeFocusOnTab: enabled
    opacity: enabled ? 1 : 0.45
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
                color: toggle.checked ? toggle.tokens.onAccent : toggle.tokens.foregroundMuted
                Behavior on x { NumberAnimation { duration: toggle.tokens.durationFast } }
            }
        }

        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: toggle.text + "  ·  " + (toggle.checked ? toggle.labelOn : toggle.labelOff)
            color: toggle.tokens.foreground
            font.pixelSize: toggle.tokens.fontBody
        }
    }

    MouseArea {
        anchors.fill: parent
        enabled: toggle.enabled
        onClicked: toggle.toggled(!toggle.checked)
    }
}
