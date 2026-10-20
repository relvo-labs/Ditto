pragma ComponentBehavior: Bound
import QtQuick

/// #116: one empty state for a candidate surface — a character (`art`, e.g.
/// the assistant's small Ditto) resting on a soft pool with a few bubbles, a
/// title, one message, one primary action, an optional quiet second action,
/// and up to three example phrases. The examples are static quotes (what one
/// could say once the feature is on, already quoted by the caller), not buttons: they take no input and no
/// Tab stop. Decoration is plain shapes; with reduced transparency or the
/// low-power style the bubbles and pool are not drawn, the content stays.
///
/// Nothing is drawn outside the item's own box (VM review 2026-10-20: in the
/// compact chat panel the character covered the tabs and an example ran
/// under the composer). A short box (`compact`) gets a smaller character,
/// bubbles kept close to it and two examples; content that still does not
/// fit scrolls inside the box instead of spilling over its neighbours.
Item {
    id: empty

    required property var tokens
    property string title: ""
    property string message: ""
    property string primaryText: ""
    property string secondaryText: ""
    property string examplesTitle: ""
    property var examples: []
    default property alias art: stage.data
    signal primaryClicked()
    signal secondaryClicked()

    readonly property real contentWidth: Math.min(width - (compact ? 2 * tokens.uiGap : tokens.uiPadCard) * 2, 420)
    /// Below this height the full layout (112 px stage, three examples)
    /// would not fit beside a header and a composer.
    property real compactBelow: 470
    readonly property bool compact: height < compactBelow
    readonly property int shownExamples: compact ? Math.min(2, examples.length) : Math.min(3, examples.length)
    /// The content does not fit even compact: it scrolls (clipped).
    readonly property bool scrolls: column.height > height
    Accessible.role: Accessible.Grouping
    Accessible.name: title

    function focusPrimary() {
        primary.forceActiveFocus(Qt.TabFocusReason);
    }

    Flickable {
        id: scroller
        objectName: "emptyStateScroller"
        anchors.fill: parent
        clip: true
        contentWidth: width
        contentHeight: Math.max(height, column.height)
        interactive: empty.scrolls
        boundsBehavior: Flickable.StopAtBounds

        Column {
            id: column
            objectName: "emptyStateColumn"
            x: Math.round((scroller.width - width) / 2)
            y: Math.max(0, Math.round((scroller.height - height) / 2))
            width: empty.contentWidth
            spacing: empty.tokens.uiGap * (empty.compact ? 1 : 1.5)

            Item {
                id: pool
                objectName: "emptyStatePool"
                width: parent.width
                height: empty.compact ? 72 : 112
                clip: true

                // The pool: a flat lavender ellipse with a bright rim (water).
                Rectangle {
                    visible: empty.tokens.uiGloss
                    width: 168
                    height: 18
                    radius: 9
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.bottom: parent.bottom
                    anchors.bottomMargin: 2
                    opacity: 0.8
                    gradient: Gradient {
                        orientation: Gradient.Horizontal
                        GradientStop { position: 0.0; color: Qt.rgba(0.80, 0.75, 0.98, 0) }
                        GradientStop { position: 0.5; color: Qt.rgba(0.80, 0.75, 0.98, 0.75) }
                        GradientStop { position: 1.0; color: Qt.rgba(0.80, 0.75, 0.98, 0) }
                    }
                }
                Repeater {
                    // Bubbles: x offset from centre, y, size. J3 has the most.
                    // Kept beside the character (within ±80 px), so they read as
                    // part of it and never as stray marks over other controls.
                    model: !empty.tokens.uiGloss ? []
                        : empty.compact ? (empty.tokens.uiJ3 ? [[-52, 10, 12], [50, 4, 9], [62, 36, 14]] : [[-50, 14, 10], [54, 24, 12]])
                        : empty.tokens.uiJ3 ? [[-74, 18, 20], [62, 6, 13], [80, 50, 22], [-80, 62, 11], [50, 74, 8], [-52, 2, 8]]
                        : [[-70, 22, 15], [72, 34, 18], [54, 4, 9]]
                    Rectangle {
                        required property var modelData
                        x: pool.width / 2 + modelData[0] - modelData[2] / 2
                        y: modelData[1]
                        width: modelData[2]
                        height: width
                        radius: width / 2
                        color: Qt.rgba(1, 1, 1, 0.28)
                        border.color: Qt.rgba(0.78, 0.72, 0.98, 0.9)
                        border.width: 1
                        Rectangle {
                            x: parent.width * 0.22; y: parent.height * 0.18
                            width: Math.max(2, parent.width * 0.28); height: width; radius: width / 2
                            color: Qt.rgba(1, 1, 1, 0.9)
                        }
                        Rectangle {
                            visible: empty.tokens.uiJ3
                            anchors.fill: parent
                            anchors.margins: 1
                            radius: width / 2
                            color: "transparent"
                            border.color: Qt.rgba(0.71, 0.91, 0.95, 0.6)
                            border.width: 1
                        }
                    }
                }
                Item {
                    id: stage
                    objectName: "emptyStateArt"
                    width: empty.compact ? 52 : 76
                    height: width
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.bottom: parent.bottom
                    anchors.bottomMargin: empty.compact ? 8 : 12
                }
            }

            Text {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
                text: empty.title
                color: empty.tokens.uiInk
                font.pixelSize: empty.tokens.uiFontPage - 4
                font.weight: Font.DemiBold
                Accessible.role: Accessible.Heading
                Accessible.name: text
            }
            Text {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
                text: empty.message
                color: empty.tokens.uiInkMuted
                font.pixelSize: empty.tokens.uiFontBody
                lineHeight: 1.3
            }
            Row {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: empty.tokens.uiGap
                Button {
                    id: primary
                    tokens: empty.tokens
                    kind: "primary"
                    text: empty.primaryText
                    onClicked: empty.primaryClicked()
                }
                Button {
                    visible: empty.secondaryText.length > 0
                    tokens: empty.tokens
                    kind: "subtle"
                    text: empty.secondaryText
                    onClicked: empty.secondaryClicked()
                }
            }

            Item { width: 1; height: empty.tokens.uiGap / 2 }

            Text {
                visible: empty.examples.length > 0 && empty.examplesTitle.length > 0
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                text: empty.examplesTitle
                color: empty.tokens.uiInkMuted
                font.pixelSize: empty.tokens.uiFontCaption
            }
            Column {
                id: quotes
                width: parent.width
                spacing: empty.tokens.uiGap
                Repeater {
                    model: empty.examples.slice(0, empty.shownExamples)
                    Rectangle {
                        id: quote
                        objectName: "emptyStateExample"
                        required property string modelData
                        anchors.horizontalCenter: parent.horizontalCenter
                        width: Math.min(quotes.width, quoteText.implicitWidth + empty.tokens.uiPadCard * 2)
                        height: quoteText.implicitHeight + empty.tokens.uiGap * 1.5
                        radius: empty.tokens.uiJ1 ? empty.tokens.uiRadiusControl : height / 2
                        bottomLeftRadius: 6
                        color: empty.tokens.uiFill("#ffffff", 0.7)
                        border.color: empty.tokens.uiCardBorder
                        border.width: 1
                        Accessible.role: Accessible.StaticText
                        Accessible.name: modelData
                        Text {
                            id: quoteText
                            anchors.centerIn: parent
                            width: Math.min(implicitWidth, quotes.width - empty.tokens.uiPadCard * 2)
                            wrapMode: Text.WordWrap
                            text: quote.modelData
                            color: empty.tokens.uiInk
                            font.pixelSize: empty.tokens.uiFontCaption + 1
                        }
                    }
                }
            }
        }
    }
}
