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
    /// A secret (an API key): shown as dots, never kept by the field after
    /// its form is done (the form clears `text`).
    property bool secret: false
    signal accepted()
    readonly property bool jelly: tokens.uiCandidate === true
    readonly property bool composing: input.inputMethodComposing || input.preeditText.length > 0

    // Kept callable so QtTest can cover preedit policy without pretending an
    // offscreen key event is a real platform input-method event.
    function handlesKey(key, inComposition) {
        return !inComposition && (key === Qt.Key_Return || key === Qt.Key_Enter);
    }

    implicitWidth: 240
    implicitHeight: jelly ? tokens.uiControlHeight + 4 : tokens.controlHeight
    radius: jelly ? tokens.uiRadiusControl : tokens.radiusSmall
    color: jelly ? (enabled ? tokens.uiFill("#ffffff", 0.92) : tokens.uiTrack) : tokens.surface
    border.color: input.activeFocus ? (jelly ? tokens.uiFocus : tokens.focus) : (jelly ? tokens.uiCardBorder : tokens.border)
    border.width: input.activeFocus ? 2 : 1

    function focusInput() {
        input.forceActiveFocus();
    }

    TextInput {
        id: input
        anchors.fill: parent
        anchors.leftMargin: field.jelly ? field.tokens.uiPadCard - 4 : field.tokens.space
        anchors.rightMargin: field.jelly ? field.tokens.uiPadCard - 4 : field.tokens.space
        verticalAlignment: TextInput.AlignVCenter
        color: field.jelly ? field.tokens.uiInk : field.tokens.foreground
        font.pixelSize: field.jelly ? field.tokens.uiFontBody : field.tokens.fontBody
        Binding on font.family {
            when: field.tokens.fontFamily.length > 0
            value: field.tokens.fontFamily
        }
        selectByMouse: true
        echoMode: field.secret ? TextInput.Password : TextInput.Normal
        readOnly: field.readOnly
        clip: true
        activeFocusOnTab: true
        Accessible.role: Accessible.EditableText
        Accessible.name: field.accessibleName
        Keys.priority: Keys.BeforeItem
        Keys.onPressed: event => {
            if (field.handlesKey(event.key, field.composing)) {
                field.accepted();
                event.accepted = true;
            } else {
                event.accepted = false;
            }
        }
        onAccepted: if (!field.composing) field.accepted()

        Text {
            anchors.verticalCenter: parent.verticalCenter
            visible: input.text.length === 0 && !input.activeFocus
            width: field.jelly ? parent.width : implicitWidth
            elide: field.jelly ? Text.ElideRight : Text.ElideNone
            text: field.placeholder
            color: field.jelly ? field.tokens.uiInkMuted : field.tokens.foregroundMuted
            font.pixelSize: field.jelly ? field.tokens.uiFontBody : field.tokens.fontBody
        }
    }
}
