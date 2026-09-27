import QtQuick

/// A titled block in a center.
Column {
    id: section

    required property var tokens
    property string title: ""
    property string note: ""
    default property alias content: body.data

    spacing: tokens.space
    width: parent ? parent.width : 400

    Text {
        text: section.title
        visible: text.length > 0
        color: section.tokens.foreground
        font.pixelSize: section.tokens.fontTitle
        font.bold: true
        Accessible.role: Accessible.Heading
        Accessible.name: text
    }

    Text {
        visible: section.note.length > 0
        width: section.width
        wrapMode: Text.WordWrap
        text: section.note
        color: section.tokens.foregroundMuted
        font.pixelSize: section.tokens.fontSmall
    }

    Column {
        id: body
        width: section.width
        spacing: section.tokens.space
    }
}
