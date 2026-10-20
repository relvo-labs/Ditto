pragma ComponentBehavior: Bound
import QtQuick

/// A titled block in a center.
///
/// With a #116 candidate style the title is a 13 px group heading, the note
/// a wrapped 12 px caption, and the content sits in a jelly card with 16 px
/// padding (`carded: false` leaves the content on the page, for blocks that
/// are themselves a list of cards). Without a style nothing here changes.
Column {
    id: section

    required property var tokens
    property string title: ""
    property string note: ""
    /// Candidate style only: wrap the content in a card.
    property bool carded: true
    default property alias content: body.data

    readonly property bool jelly: tokens.uiCandidate === true

    spacing: jelly ? tokens.uiGap : tokens.space
    width: parent ? parent.width : 400

    Text {
        objectName: "sectionTitle"
        text: section.title
        visible: text.length > 0
        width: section.jelly ? section.width : implicitWidth
        wrapMode: section.jelly ? Text.WordWrap : Text.NoWrap
        color: section.jelly ? section.tokens.uiInkMuted : section.tokens.foreground
        font.pixelSize: section.jelly ? section.tokens.uiFontGroup : section.tokens.fontTitle
        font.bold: !section.jelly
        font.weight: section.jelly ? Font.DemiBold : Font.Bold
        font.letterSpacing: section.jelly ? 0.4 : 0
        leftPadding: section.jelly ? section.tokens.uiGap / 2 : 0
        Accessible.role: Accessible.Heading
        Accessible.name: text
    }

    Text {
        objectName: "sectionNote"
        visible: section.note.length > 0
        width: section.width
        wrapMode: Text.WordWrap
        text: section.note
        color: section.jelly ? section.tokens.uiInkMuted : section.tokens.foregroundMuted
        font.pixelSize: section.jelly ? section.tokens.uiFontCaption : section.tokens.fontSmall
        lineHeight: section.jelly ? 1.3 : 1.0
        leftPadding: section.jelly ? section.tokens.uiGap / 2 : 0
        rightPadding: leftPadding
    }

    Item {
        id: holder
        readonly property bool card: section.jelly && section.carded
        readonly property int pad: card ? section.tokens.uiPadCard : 0
        width: section.width
        height: body.implicitHeight + pad * 2

        Loader {
            anchors.fill: parent
            active: holder.card
            sourceComponent: JellySurface {
                objectName: "sectionCard"
                tokens: section.tokens
                iris: section.tokens.uiJ3 === true
            }
        }

        Column {
            id: body
            x: holder.pad
            y: holder.pad
            width: section.width - holder.pad * 2
            spacing: section.jelly ? section.tokens.uiGap * 1.5 : section.tokens.space
        }
    }
}
