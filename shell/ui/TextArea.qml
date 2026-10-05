import QtQuick

/// Multi-line text (import/export of a composition). Scrolls; selectable.
/// Tab and Shift+Tab move focus on, as in every other control.
Rectangle {
    id: area

    required property var tokens
    property alias text: edit.text
    property bool readOnly: false
    property string accessibleName: ""

    implicitWidth: 400
    implicitHeight: 160
    radius: tokens.radiusSmall
    color: tokens.surface
    border.color: edit.activeFocus ? tokens.focus : tokens.border
    border.width: edit.activeFocus ? 2 : 1
    clip: true

    Flickable {
        id: flick
        anchors.fill: parent
        anchors.margins: area.tokens.space
        contentWidth: width
        contentHeight: edit.implicitHeight
        boundsBehavior: Flickable.StopAtBounds

        TextEdit {
            id: edit
            width: flick.width
            wrapMode: TextEdit.WrapAnywhere
            color: area.tokens.foreground
            font.pixelSize: area.tokens.fontSmall
            font.family: "monospace"
            selectByMouse: true
            readOnly: area.readOnly
            activeFocusOnTab: true
            // Tab leaves the field instead of typing a tab character, so the
            // keyboard is never trapped here; pasted text keeps its tabs.
            Keys.onTabPressed: event => {
                const next = edit.nextItemInFocusChain(true);
                if (next) {
                    next.forceActiveFocus(Qt.TabFocusReason);
                }
            }
            Keys.onBacktabPressed: event => {
                const previous = edit.nextItemInFocusChain(false);
                if (previous) {
                    previous.forceActiveFocus(Qt.BacktabFocusReason);
                }
            }
            Accessible.role: Accessible.EditableText
            Accessible.name: area.accessibleName
        }
    }
}
