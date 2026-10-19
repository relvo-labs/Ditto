pragma ComponentBehavior: Bound
import QtQuick

/// #116: the `⋯` button of a card and the menu it opens, for the actions
/// beyond a card's (at most two) main ones. `items` is a list of
/// { id, label, danger?, enabled?, reason? }; destructive items are drawn in
/// the danger colour below a divider, and a disabled item says why (in its
/// text and its accessible name). `triggered(id)` fires once per choice.
///
/// Keyboard: Enter/Space/Down on the button opens and focuses the first
/// available item; Up/Down move (wrapping, skipping unavailable items);
/// Enter/Space choose; Escape or Tab close and give focus back to the button.
/// Escape stops here, so it never also closes the surrounding window. A click
/// outside closes without choosing. The menu is drawn over the window's
/// content (the window's root item), not clipped by a scrolling page.
Item {
    id: menu

    required property var tokens
    property var items: []
    property string accessibleName: ""
    property bool open: false
    /// The focus ring is drawn when the menu was opened from the keyboard.
    property bool keyboardOpened: false
    readonly property alias popupItem: popup
    signal triggered(string id)

    implicitWidth: button.width
    implicitHeight: button.height

    function available(item) {
        return item.enabled !== false;
    }
    function itemAt(index) {
        return repeater.itemAt(index);
    }
    function focusStep(from, step) {
        const count = items.length;
        for (let n = 1; n <= count; n++) {
            const index = ((from + step * n) % count + count) % count;
            if (available(items[index])) {
                itemAt(index).forceActiveFocus(Qt.TabFocusReason);
                return;
            }
        }
    }
    function openMenu(fromKeyboard) {
        keyboardOpened = fromKeyboard !== false;
        const window = menu.Window.window;
        overlay.parent = window && window.contentItem ? window.contentItem : menu;
        overlay.visible = true;
        open = true;
        place();
        focusStep(-1, 1);
    }
    function closeMenu(returnFocus) {
        if (!open) return;
        open = false;
        overlay.visible = false;
        overlay.parent = menu;
        if (returnFocus !== false) button.forceActiveFocus(Qt.TabFocusReason);
    }
    function choose(entry) {
        if (!available(entry)) return;
        closeMenu(true);
        triggered(entry.id);
    }
    function place() {
        const host = overlay.parent;
        const below = button.mapToItem(host, button.width, button.height + 4);
        const above = button.mapToItem(host, button.width, -4);
        popup.x = Math.max(8, Math.min(host.width - popup.width - 8, below.x - popup.width));
        popup.y = below.y + popup.height <= host.height - 8 ? below.y : Math.max(8, above.y - popup.height);
    }
    onVisibleChanged: if (!visible) closeMenu(false)
    Component.onDestruction: overlay.parent = menu

    Rectangle {
        id: button
        objectName: "overflowButton"
        width: menu.tokens.uiControlHeight
        height: menu.tokens.uiControlHeight
        radius: width / 2
        color: menu.open ? menu.tokens.uiTonalHover
            : area.containsMouse ? menu.tokens.uiGhostHover : "transparent"
        border.color: menu.tokens.uiCardBorder
        border.width: 1
        activeFocusOnTab: true
        Accessible.role: Accessible.ButtonMenu
        Accessible.name: menu.accessibleName
        Accessible.onPressAction: menu.open ? menu.closeMenu(true) : menu.openMenu()
        Keys.onReturnPressed: menu.openMenu()
        Keys.onEnterPressed: menu.openMenu()
        Keys.onSpacePressed: menu.openMenu()
        Keys.onDownPressed: menu.openMenu()

        Row {
            anchors.centerIn: parent
            spacing: 3
            Repeater {
                model: 3
                Rectangle {
                    width: 4; height: 4; radius: 2
                    color: menu.tokens.uiInk
                }
            }
        }
        Rectangle {
            anchors.fill: parent
            anchors.margins: -3
            radius: width / 2
            color: "transparent"
            border.color: menu.tokens.uiFocus
            border.width: button.activeFocus ? 2 : 0
        }
        MouseArea {
            id: area
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: menu.open ? menu.closeMenu(true) : menu.openMenu(false)
        }
    }

    /// Over the whole window while open: a click outside the menu closes it.
    Item {
        id: overlay
        visible: false
        width: parent ? parent.width : 0
        height: parent ? parent.height : 0
        z: 10000

        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.AllButtons
            onPressed: menu.closeMenu(false)
            onWheel: wheel => wheel.accepted = true
        }

        Item {
            id: popup
            objectName: "overflowMenu"
            width: Math.round(248 * menu.tokens.fontScale)
            height: list.implicitHeight + menu.tokens.uiGap * 2
            Accessible.role: Accessible.PopupMenu
            Accessible.name: menu.accessibleName

            JellySurface {
                anchors.fill: parent
                tokens: menu.tokens
                fill: menu.tokens.uiFill("#ffffff", 0.97)
                radius: menu.tokens.uiRadiusCard > 16 ? 18 : 14
                lift: 1.2
                iris: menu.tokens.uiJ3 === true
            }
            MouseArea { anchors.fill: parent }

            Column {
                id: list
                x: menu.tokens.uiGap
                y: menu.tokens.uiGap
                width: popup.width - menu.tokens.uiGap * 2

                Repeater {
                    id: repeater
                    model: menu.items

                    Item {
                        id: entry
                        required property var modelData
                        required property int index
                        readonly property bool usable: menu.available(modelData)
                        readonly property bool firstDanger: modelData.danger === true
                            && (index === 0 || menu.items[index - 1].danger !== true)
                        objectName: "overflowItem_" + modelData.id
                        width: list.width
                        height: divider.height + face.height
                        Accessible.role: Accessible.MenuItem
                        Accessible.name: modelData.label + (!usable && modelData.reason ? " · " + modelData.reason : "")
                        Accessible.onPressAction: menu.choose(modelData)
                        Keys.onReturnPressed: menu.choose(modelData)
                        Keys.onEnterPressed: menu.choose(modelData)
                        Keys.onSpacePressed: menu.choose(modelData)
                        Keys.onDownPressed: { menu.keyboardOpened = true; menu.focusStep(index, 1); }
                        Keys.onUpPressed: { menu.keyboardOpened = true; menu.focusStep(index, -1); }
                        Keys.onEscapePressed: menu.closeMenu(true)
                        Keys.onTabPressed: menu.closeMenu(true)
                        Keys.onBacktabPressed: menu.closeMenu(true)

                        Item {
                            id: divider
                            width: parent.width
                            height: entry.firstDanger && entry.index > 0 ? menu.tokens.uiGap * 2 + 1 : 0
                            Rectangle {
                                objectName: entry.firstDanger && entry.index > 0 ? "overflowDangerDivider" : ""
                                visible: entry.firstDanger && entry.index > 0
                                anchors.verticalCenter: parent.verticalCenter
                                x: menu.tokens.uiGap
                                width: parent.width - menu.tokens.uiGap * 2
                                height: 1
                                color: menu.tokens.uiSeparator
                            }
                        }

                        Rectangle {
                            id: face
                            y: divider.height
                            width: parent.width
                            height: Math.max(36, column.implicitHeight + menu.tokens.uiGap * 1.5)
                            radius: menu.tokens.uiRadiusControl
                            color: entry.activeFocus || (hover.containsMouse && entry.usable)
                                ? (entry.modelData.danger ? menu.tokens.uiDangerFill : menu.tokens.uiTonal) : "transparent"
                            border.color: menu.tokens.uiFocus
                            border.width: entry.activeFocus && menu.keyboardOpened ? 2 : 0

                            Column {
                                id: column
                                anchors.verticalCenter: parent.verticalCenter
                                x: menu.tokens.uiPadCard - menu.tokens.uiGap / 2
                                width: parent.width - x * 2
                                spacing: 2
                                Text {
                                    id: itemLabel
                                    objectName: "overflowLabel_" + entry.modelData.id
                                    width: parent.width
                                    wrapMode: Text.WordWrap
                                    text: entry.modelData.label
                                    color: !entry.usable ? menu.tokens.uiInkDisabled
                                        : entry.modelData.danger ? menu.tokens.uiDanger : menu.tokens.uiInk
                                    font.pixelSize: menu.tokens.uiFontBody
                                    font.weight: entry.modelData.danger ? Font.DemiBold : Font.Normal
                                }
                                Text {
                                    id: reason
                                    visible: !entry.usable && !!entry.modelData.reason
                                    width: parent.width
                                    wrapMode: Text.WordWrap
                                    text: entry.modelData.reason || ""
                                    color: menu.tokens.uiInkMuted
                                    font.pixelSize: menu.tokens.uiFontCaption
                                }
                            }

                            MouseArea {
                                id: hover
                                anchors.fill: parent
                                hoverEnabled: true
                                enabled: entry.usable
                                cursorShape: Qt.PointingHandCursor
                                onClicked: menu.choose(entry.modelData)
                            }
                        }
                    }
                }
            }
        }
    }
}
