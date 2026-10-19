import QtQuick

/// The expandable diagnostics area: contract ids, raw errors, process
/// details. Collapsed by default; the normal path never needs it.
Column {
    id: diagnostics

    required property var tokens
    property string title: "Diagnostics"
    property string text: ""
    property bool expanded: false
    readonly property bool jelly: tokens.uiCandidate === true

    spacing: tokens.spaceTight
    visible: text.length > 0

    Text {
        text: (diagnostics.expanded ? "▾ " : "▸ ") + diagnostics.title
        color: diagnostics.jelly ? diagnostics.tokens.uiInkMuted : diagnostics.tokens.foregroundMuted
        font.pixelSize: diagnostics.jelly ? diagnostics.tokens.uiFontCaption : diagnostics.tokens.fontSmall
        activeFocusOnTab: true
        Accessible.role: Accessible.Button
        Accessible.name: diagnostics.title
        Keys.onReturnPressed: diagnostics.expanded = !diagnostics.expanded
        Keys.onSpacePressed: diagnostics.expanded = !diagnostics.expanded

        Rectangle {
            anchors.fill: parent
            anchors.margins: -2
            color: "transparent"
            border.color: diagnostics.jelly ? diagnostics.tokens.uiFocus : diagnostics.tokens.focus
            border.width: parent.activeFocus ? 1 : 0
        }

        MouseArea {
            anchors.fill: parent
            onClicked: diagnostics.expanded = !diagnostics.expanded
        }
    }

    TextEdit {
        visible: diagnostics.expanded
        width: diagnostics.width
        readOnly: true
        selectByMouse: true
        wrapMode: TextEdit.WrapAnywhere
        text: diagnostics.text
        color: diagnostics.jelly ? diagnostics.tokens.uiInkMuted : diagnostics.tokens.foregroundMuted
        font.pixelSize: diagnostics.jelly ? diagnostics.tokens.uiFontCaption : diagnostics.tokens.fontSmall
        font.family: "monospace"
    }
}
