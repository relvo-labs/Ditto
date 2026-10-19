import QtQuick

/// Multi-line text (import/export of a composition). Scrolls; selectable.
/// Tab and Shift+Tab move focus on, as in every other control.
Rectangle {
    id: area

    required property var tokens
    property alias text: edit.text
    property bool readOnly: false
    property string accessibleName: ""
    readonly property bool jelly: tokens.uiCandidate === true

    implicitWidth: 400
    implicitHeight: 160
    radius: jelly ? tokens.uiRadiusControl : tokens.radiusSmall
    color: jelly ? tokens.uiFill("#ffffff", 0.92) : tokens.surface
    border.color: edit.activeFocus ? (jelly ? tokens.uiFocus : tokens.focus) : (jelly ? tokens.uiCardBorder : tokens.border)
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
            color: area.jelly ? area.tokens.uiInk : area.tokens.foreground
            font.pixelSize: area.jelly ? area.tokens.uiFontCaption : area.tokens.fontSmall
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
