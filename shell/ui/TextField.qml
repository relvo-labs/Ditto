import QtQuick

/// A single-line text field. Text input goes through the compositor's
/// text-input protocol, so an input method (Chinese input included) works
/// here like in any Qt application; copy and paste use the standard
/// clipboard protocol.
Rectangle {
    id: field

    required property var tokens
    property alias text: input.text
    property string placeholder: ""
    property string accessibleName: placeholder
    property bool readOnly: false
    signal accepted()

    implicitWidth: 240
    implicitHeight: tokens.controlHeight
    radius: tokens.radiusSmall
    color: tokens.surface
    border.color: input.activeFocus ? tokens.focus : tokens.border
    border.width: input.activeFocus ? 2 : 1

    function focusInput() {
        input.forceActiveFocus();
    }

    TextInput {
        id: input
        anchors.fill: parent
        anchors.leftMargin: field.tokens.space
        anchors.rightMargin: field.tokens.space
        verticalAlignment: TextInput.AlignVCenter
        color: field.tokens.foreground
        font.pixelSize: field.tokens.fontBody
        Binding on font.family {
            when: field.tokens.fontFamily.length > 0
            value: field.tokens.fontFamily
        }
        selectByMouse: true
        readOnly: field.readOnly
        clip: true
        activeFocusOnTab: true
        Accessible.role: Accessible.EditableText
        Accessible.name: field.accessibleName
        onAccepted: field.accepted()

        Text {
            anchors.verticalCenter: parent.verticalCenter
            visible: input.text.length === 0 && !input.activeFocus
            text: field.placeholder
            color: field.tokens.foregroundMuted
            font.pixelSize: field.tokens.fontBody
        }
    }
}
