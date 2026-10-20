pragma ComponentBehavior: Bound
import QtQuick
import "../jelly"

/// #116: the application-style choice of personalization (owner 2026-10-20:
/// three styles, J1 jelly glass by default). One card per style, each with a
/// small live preview drawn by that style's own tokens, its name and one
/// line of description. The chosen card has a ring and a filled marker in
/// front of its name (never the primary-action fill); keyboard focus is a
/// separate outer ring.
///
/// Keyboard: one Tab stop (the chosen card); Left/Right/Up/Down move, Home/
/// End jump, Enter/Space choose. Moving focus does not choose: choosing is a
/// ChangeSet, so it happens only on purpose. Each card is a RadioButton with
/// its name (and "default") as accessible name and the description as its
/// accessible description. `options` is a list of { value, label, caption,
/// accessibleName }; the caller translates them and applies `chosen(value)`.
Item {
    id: picker

    required property var tokens
    property var options: []
    property string value: ""
    property string accessibleName: ""
    /// The default style carries a small tag with this text, e.g. 「預設」.
    property string defaultValue: "j1"
    property string defaultNote: ""
    signal chosen(string value)

    readonly property int selectedIndex: {
        for (let i = 0; i < options.length; i++) {
            if (options[i].value === value) return i;
        }
        return -1;
    }
    readonly property int tabIndex: selectedIndex >= 0 ? selectedIndex : 0
    readonly property int gap: Math.max(8, tokens.uiGap * 1.5)
    readonly property int columns: width >= 3 * 168 + 2 * gap ? 3 : (width >= 2 * 168 + gap ? 2 : 1)
    readonly property real cardWidth: Math.floor((width - gap * (columns - 1)) / Math.max(1, columns))
    /// Every card as tall as the tallest (a wrapped description), so the
    /// three read as one set. Each card reports its own content height.
    property var contentHeights: ({})
    readonly property real cardHeight: {
        let tallest = 0;
        for (const key in contentHeights) tallest = Math.max(tallest, contentHeights[key]);
        return tallest;
    }
    function noteHeight(index, value) {
        const next = Object.assign({}, contentHeights);
        next[index] = value;
        contentHeights = next;
    }

    implicitWidth: 3 * 200 + 2 * gap
    implicitHeight: grid.height
    Accessible.role: Accessible.Grouping
    Accessible.name: accessibleName

    function card(index) {
        return repeater.itemAt(index);
    }
    function focusCard(index) {
        const count = options.length;
        if (count === 0) return;
        const item = card(((index % count) + count) % count);
        if (item) item.forceActiveFocus(Qt.TabFocusReason);
    }

    Flow {
        id: grid
        width: picker.width
        spacing: picker.gap

        Repeater {
            id: repeater
            model: picker.options

            Item {
                id: card
                required property var modelData
                required property int index
                readonly property bool selected: index === picker.selectedIndex
                objectName: "styleCard_" + modelData.value
                readonly property real contentHeight: body.height
                onContentHeightChanged: picker.noteHeight(index, contentHeight)
                Component.onCompleted: picker.noteHeight(index, contentHeight)
                width: picker.cardWidth
                height: Math.max(body.height, picker.cardHeight)
                activeFocusOnTab: picker.enabled && index === picker.tabIndex
                Accessible.role: Accessible.RadioButton
                Accessible.name: modelData.accessibleName || modelData.label
                Accessible.description: modelData.caption || ""
                Accessible.checked: selected
                Accessible.onPressAction: if (picker.enabled) picker.chosen(modelData.value)
                Keys.onSpacePressed: if (picker.enabled) picker.chosen(modelData.value)
                Keys.onReturnPressed: if (picker.enabled) picker.chosen(modelData.value)
                Keys.onEnterPressed: if (picker.enabled) picker.chosen(modelData.value)
                Keys.onRightPressed: picker.focusCard(index + 1)
                Keys.onDownPressed: picker.focusCard(index + 1)
                Keys.onLeftPressed: picker.focusCard(index - 1)
                Keys.onUpPressed: picker.focusCard(index - 1)
                Keys.onPressed: event => {
                    if (event.key === Qt.Key_Home) { picker.focusCard(0); event.accepted = true; }
                    else if (event.key === Qt.Key_End) { picker.focusCard(picker.options.length - 1); event.accepted = true; }
                }

                /// This card's own style, for the preview only: the person's
                /// reduced transparency / low power apply to it too.
                Tokens {
                    id: preview
                    readsSystemPreference: false
                    systemReducedMotion: picker.tokens.systemReducedMotion
                    appearance: ({
                        theme: "soft-jelly-light",
                        tokens: { ui_style: card.modelData.value },
                        reduced_transparency: picker.tokens.reducedTransparency,
                        low_power_style: picker.tokens.lowPower
                    })
                }

                Rectangle {
                    id: frame
                    objectName: "styleCardFrame"
                    anchors.fill: parent
                    radius: picker.tokens.appPlateRadius + 6
                    color: hover.containsMouse && picker.enabled && !card.selected ? Qt.tint(picker.tokens.appPlate, Qt.rgba(0.42, 0.33, 0.84, 0.06)) : picker.tokens.appPlate
                    border.color: card.selected ? (picker.tokens.uiCandidate ? picker.tokens.uiSelectDot : picker.tokens.accent) : picker.tokens.appPlateBorder
                    border.width: card.selected ? 2 : 1
                }

                Column {
                    id: body
                    width: parent.width
                    padding: 10
                    spacing: 8

                    // ---- the preview: a tiny window of this style ------------------
                    Item {
                        id: miniature
                        objectName: "stylePreview"
                        width: body.width - body.padding * 2
                        height: 92
                        Accessible.ignored: true

                        JellySurface {
                            id: window
                            anchors.fill: parent
                            tokens: preview
                            radius: Math.round(preview.uiRadiusWindow * 0.6)
                            fill: preview.uiCanvas
                            fillTop: preview.uiJ3 ? preview.uiFill("#ffffff", 0.9) : preview.uiCanvas
                            edge: preview.uiCardBorder
                            lift: 0.6
                            iris: preview.uiJ3
                        }
                        // J3's bubbles (the frame's own need a wider surface).
                        Repeater {
                            model: preview.uiJ3 && preview.uiGloss ? [[0.08, 0.80, 12], [0.15, 0.68, 6]] : []
                            Rectangle {
                                required property var modelData
                                x: miniature.width * modelData[0]
                                y: miniature.height * modelData[1]
                                width: modelData[2]; height: width; radius: width / 2
                                color: Qt.rgba(1, 1, 1, 0.2)
                                border.color: Qt.rgba(0.48, 0.62, 0.86, 0.7)
                                border.width: 1
                            }
                        }
                        // Window beads.
                        Row {
                            anchors.right: parent.right
                            anchors.rightMargin: 8
                            y: 7
                            spacing: 4
                            Repeater {
                                model: [preview.uiBeadMinimize, preview.uiBeadMaximize, preview.uiBeadClose]
                                Rectangle {
                                    required property color modelData
                                    width: 8; height: 8; radius: 4
                                    color: preview.uiJ3 ? "transparent" : modelData
                                    border.color: preview.uiJ3 ? preview.uiBeadRim : Qt.darker(modelData, 1.12)
                                    border.width: preview.uiJ3 ? 1.5 : 1
                                }
                            }
                        }
                        // Sidebar with its selected item.
                        Rectangle {
                            x: 6; y: 20
                            width: miniature.width * 0.3
                            height: miniature.height - 26
                            radius: Math.round(preview.uiRadiusCard * 0.45)
                            color: preview.uiSidebar
                            JellySurface {
                                x: 4; y: 5
                                width: parent.width - 8
                                height: 13
                                tokens: preview
                                radius: preview.uiJ1 ? 4 : height / 2
                                fill: preview.uiJ2 ? preview.uiSelectFill : preview.uiFill("#ffffff", 0.92)
                                edge: preview.uiBeadEdge
                                lift: 0.4
                                iris: preview.uiJ3
                                Rectangle {
                                    x: 5; anchors.verticalCenter: parent.verticalCenter
                                    width: 4; height: 4; radius: 2
                                    color: preview.uiJ3 ? "transparent" : preview.uiSelectDot
                                    border.color: preview.uiSelectDot
                                    border.width: preview.uiJ3 ? 1 : 0
                                }
                            }
                            Repeater {
                                model: 2
                                Rectangle {
                                    required property int index
                                    x: 10; y: 26 + index * 11
                                    width: parent.width * (0.55 - index * 0.12); height: 3; radius: 1.5
                                    color: Qt.rgba(0.32, 0.30, 0.44, 0.35)
                                }
                            }
                        }
                        // A card with two lines of text and the primary action.
                        JellySurface {
                            x: miniature.width * 0.3 + 12
                            y: 20
                            width: miniature.width - x - 6
                            height: miniature.height - 26
                            tokens: preview
                            radius: Math.round(preview.uiRadiusCard * 0.5)
                            fill: preview.uiCard
                            edge: preview.uiCardBorder
                            lift: 0.5
                            iris: preview.uiJ3
                            Rectangle {
                                x: 8; y: 9; width: parent.width * 0.55; height: 4; radius: 2
                                color: preview.uiInk
                            }
                            Rectangle {
                                x: 8; y: 18; width: parent.width * 0.75; height: 3; radius: 1.5
                                color: Qt.rgba(0.32, 0.30, 0.44, 0.4)
                            }
                            JellySurface {
                                anchors.right: parent.right
                                anchors.bottom: parent.bottom
                                anchors.margins: 7
                                width: 38; height: 14
                                tokens: preview
                                radius: preview.uiJ1 ? 4 : height / 2
                                fill: preview.uiAccent
                                fillTop: preview.uiAccentTop
                                edge: Qt.darker(preview.uiAccent, 1.08)
                                lipColor: preview.uiAccentLip
                                lift: 0.7
                            }
                            Rectangle {
                                anchors.right: parent.right
                                anchors.bottom: parent.bottom
                                anchors.rightMargin: 50
                                anchors.bottomMargin: 7
                                width: 30; height: 14
                                radius: preview.uiJ1 ? 4 : height / 2
                                color: preview.uiTonal
                                border.color: preview.uiCardBorder
                                border.width: 1
                            }
                        }
                    }

                    // ---- name and description -----------------------------------------
                    Row {
                        width: body.width - body.padding * 2
                        spacing: 6
                        /// The chosen card's marker: a filled bead, not a ✓.
                        Rectangle {
                            objectName: "styleMarker"
                            visible: card.selected
                            anchors.verticalCenter: name.verticalCenter
                            width: 8; height: 8; radius: 4
                            color: picker.tokens.uiCandidate ? picker.tokens.uiSelectDot : picker.tokens.accent
                        }
                        Text {
                            id: name
                            objectName: "styleName"
                            width: parent.width - (card.selected ? 14 : 0) - (defaultTag.visible ? defaultTag.width + 6 : 0)
                            elide: Text.ElideRight
                            text: card.modelData.label
                            color: picker.enabled ? picker.tokens.appInk : picker.tokens.appInkMuted
                            font.pixelSize: picker.tokens.uiCandidate ? picker.tokens.uiFontLabel : picker.tokens.fontBody
                            font.weight: card.selected ? Font.DemiBold : Font.Medium
                        }
                        Rectangle {
                            id: defaultTag
                            visible: card.modelData.value === picker.defaultValue && picker.defaultNote.length > 0
                            anchors.verticalCenter: name.verticalCenter
                            width: defaultText.implicitWidth + 12
                            height: defaultText.implicitHeight + 4
                            radius: height / 2
                            color: picker.tokens.appPlateStrong
                            Text {
                                id: defaultText
                                anchors.centerIn: parent
                                text: picker.defaultNote
                                color: picker.tokens.appInkMuted
                                font.pixelSize: picker.tokens.appFontCaption
                            }
                        }
                    }
                    Text {
                        objectName: "styleCaption"
                        width: body.width - body.padding * 2
                        wrapMode: Text.WordWrap
                        text: card.modelData.caption || ""
                        color: picker.tokens.appInkMuted
                        font.pixelSize: picker.tokens.appFontCaption
                        lineHeight: 1.25
                    }
                }

                Rectangle {
                    objectName: "styleFocusRing"
                    anchors.fill: parent
                    anchors.margins: -3
                    radius: frame.radius + 3
                    color: "transparent"
                    border.color: picker.tokens.uiCandidate ? picker.tokens.uiFocus : picker.tokens.focus
                    border.width: card.activeFocus ? 2 : 0
                }

                MouseArea {
                    id: hover
                    anchors.fill: parent
                    hoverEnabled: true
                    enabled: picker.enabled
                    cursorShape: Qt.PointingHandCursor
                    onClicked: picker.chosen(card.modelData.value)
                }
            }
        }
    }
}
