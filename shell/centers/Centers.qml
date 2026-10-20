pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import "../ui"

/// The four centers in one window: composition, plugins, change history and
/// personalization. The window exists only while open; a closed center
/// renders nothing and reads nothing (RUN-07). Every read goes through
/// `client`; every write is a ChangeSet (or, for naming and deleting a
/// composition, the profile capability that changes no content).
FloatingWindow {
    id: window

    property var client: null
    property var tokens: null
    property var providers: null
    property var conversation: null
    property string page: "composition"
    signal closeRequested()

    /// #116 application style (Profile `ui_style`, light recipe); false
    /// keeps the existing window.
    readonly property bool jelly: !!tokens && tokens.uiCandidate === true
    /// The screen's height when known. A styled window leaves
    /// `tokens.uiWindowClearance` of it free, so that where Wayfire centres
    /// it (in the work area or on the output) its title row is below the top
    /// bar and the tasks panel under it, and its bottom above the Dock (VM
    /// 2026-10-20: a 740 px window on a 900 px screen had its title under
    /// the tasks panel).
    readonly property real screenHeight: screen && screen.height ? screen.height : 0

    function t(source) {
        return client ? client.t(source) : source;
    }

    readonly property var pages: [
        { id: "composition", label: qsTr("組合中心") },
        { id: "plugins", label: qsTr("插件中心") },
        { id: "history", label: qsTr("變更紀錄") },
        { id: "personalization", label: qsTr("個人化設定") },
        { id: "ai", label: qsTr("AI 設定") }
    ]

    title: t(qsTr("Ditto 設定"))
    implicitWidth: 1080
    implicitHeight: jelly && screenHeight > 0 ? Math.max(520, Math.min(740, screenHeight - tokens.uiWindowClearance)) : 740
    minimumSize: Qt.size(760, 520)
    color: jelly ? "transparent" : tokens ? tokens.background : "#12121a"
    visible: true
    onClosed: window.closeRequested()

    /// The control that has keyboard focus, for the `focus` line on the
    /// Shell's control socket (a keyboard-driven verification run asks it
    /// where Tab has taken it, the way a screen reader would).
    readonly property Item focusedItem: centersRoot.Window.activeFocusItem
    readonly property Item diagnosticRoot: centersRoot

    /// A control that disappears while it has focus (「套用」 once applied,
    /// a confirm row once confirmed, 「使用這個組合」 once in use) would
    /// leave a keyboard user with no focus at all. Focus moves instead to the
    /// nearest earlier control that is still there.
    property Item lastFocused: null
    onFocusedItemChanged: {
        if (focusedItem && focusedItem !== centersRoot) {
            lastFocused = focusedItem;
            revealFocused();
        } else {
            Qt.callLater(recoverFocus);
        }
    }
    /// Tab to a control below (or above) the visible part of a page scrolls
    /// the page so the whole control shows, with a little room around it;
    /// a keyboard user can reach the last saved composition's actions.
    /// The current page (every page is a Flickable).
    readonly property Flickable pageFlick: content.item as Flickable
    function revealFocused() {
        const flick = pageFlick;
        if (!flick || !focusedItem) return;
        let ancestor = focusedItem.parent;
        while (ancestor && ancestor !== flick.contentItem) ancestor = ancestor.parent;
        if (!ancestor) return;
        const box = focusedItem.mapToItem(flick.contentItem, 0, 0, focusedItem.width, focusedItem.height);
        const room = 16;
        const maxY = Math.max(0, flick.contentHeight - flick.height);
        if (box.y - room < flick.contentY) {
            flick.contentY = Math.max(0, box.y - room);
        } else if (box.y + box.height + room > flick.contentY + flick.height) {
            flick.contentY = Math.min(maxY, box.y + box.height + room - flick.height);
        }
    }
    function recoverFocus() {
        if (focusedItem && focusedItem !== centersRoot) {
            return;
        }
        let target = lastFocused;
        for (let step = 0; target && step < 500; step++) {
            target = target.nextItemInFocusChain(false);
            if (target && target.visible && target.enabled && target !== lastFocused) {
                target.forceActiveFocus(Qt.OtherFocusReason);
                return;
            }
        }
        centersRoot.forceActiveFocus(Qt.OtherFocusReason);
    }

    Item {
        id: centersRoot
        anchors.fill: parent
        focus: true
        Keys.onEscapePressed: window.closeRequested()
        // Unhandled by the focused control: page the content (styled only).
        Keys.onPressed: event => {
            const flick = window.pageFlick;
            if (!window.jelly || !flick) return;
            const step = Math.max(40, flick.height - 48);
            const maxY = Math.max(0, flick.contentHeight - flick.height);
            if (event.key === Qt.Key_PageDown) { flick.contentY = Math.min(maxY, flick.contentY + step); event.accepted = true; }
            else if (event.key === Qt.Key_PageUp) { flick.contentY = Math.max(0, flick.contentY - step); event.accepted = true; }
        }

        // ---- #116 candidate frame: the window's one title and its controls ----
        Loader {
            anchors.fill: parent
            active: window.jelly
            sourceComponent: JellySurface {
                objectName: "centersFrame"
                tokens: window.tokens
                radius: window.tokens.uiRadiusWindow
                fill: window.tokens.uiJ3 && window.tokens.uiGloss ? window.tokens.uiCanvasLow : window.tokens.uiCanvas
                fillTop: window.tokens.uiGloss ? Qt.lighter(window.tokens.uiCanvas, 1.03) : window.tokens.uiCanvas
                raised: false
                iris: window.tokens.uiJ3
                bubbles: true
            }
        }
        Loader {
            id: header
            active: window.jelly
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            sourceComponent: WindowHeader {
                tokens: window.tokens
                hostWindow: window
                title: window.title
                minimizeText: window.t(qsTr("縮小視窗"))
                maximizeText: window.t(qsTr("放大視窗"))
                restoreText: window.t(qsTr("還原視窗大小"))
                closeText: window.t(qsTr("關閉 Ditto 設定"))
                onCloseRequested: window.closeRequested()
            }
        }

        Rectangle {
            id: sidebar
            width: window.jelly ? 216 : 200
            anchors.top: window.jelly ? header.bottom : parent.top
            anchors.bottom: parent.bottom
            anchors.bottomMargin: window.jelly ? window.tokens.uiGap : 0
            anchors.left: parent.left
            anchors.leftMargin: window.jelly ? window.tokens.uiGap : 0
            radius: window.jelly ? window.tokens.uiRadiusCard : 0
            color: window.jelly ? window.tokens.uiSidebar : window.tokens.surfaceStrong
            // J3: the sidebar is told from the page by an edge, not only a tint.
            border.color: window.jelly && window.tokens.uiJ3 ? window.tokens.uiCardBorder : "transparent"
            border.width: window.jelly && window.tokens.uiJ3 ? 1 : 0

            Column {
                anchors.fill: parent
                anchors.margins: window.tokens.spaceWide
                spacing: window.tokens.spaceTight

                // The candidate shows the title once, in the header.
                Text {
                    visible: !window.jelly
                    text: "Ditto"
                    color: window.tokens.foreground
                    font.pixelSize: window.tokens.fontHeading
                    font.bold: true
                    bottomPadding: window.tokens.spaceWide
                }

                Repeater {
                    model: window.pages

                    Rectangle {
                        required property var modelData
                        readonly property bool current: window.page === modelData.id
                        width: parent.width
                        height: window.jelly ? window.tokens.uiControlHeight + 8 : window.tokens.controlHeight + 4
                        radius: window.jelly ? (window.tokens.uiJ1 ? window.tokens.uiRadiusControl : height / 2) : window.tokens.radiusSmall
                        color: window.jelly ? (tabArea.containsMouse && !current ? window.tokens.uiGhostHover : "transparent")
                            : current ? window.tokens.accent : (tabArea.containsMouse ? window.tokens.surface : "transparent")
                        activeFocusOnTab: true
                        Accessible.role: Accessible.PageTab
                        Accessible.name: tabText.text
                        Accessible.selected: current
                        Keys.onReturnPressed: window.page = modelData.id
                        Keys.onSpacePressed: window.page = modelData.id

                        // Candidate: the selected page is a raised bubble with
                        // a filled marker; never the primary-action fill.
                        Loader {
                            anchors.fill: parent
                            active: window.jelly && parent.current
                            sourceComponent: JellySurface {
                                objectName: "centersTabBubble"
                                tokens: window.tokens
                                radius: window.tokens.uiJ1 ? window.tokens.uiRadiusControl : height / 2
                                fill: window.tokens.uiJ3 ? window.tokens.uiFill("#ffffff", 0.85) : window.tokens.uiSelectFill
                                edge: window.tokens.uiBeadEdge
                                lift: 0.5
                                iris: window.tokens.uiJ3
                            }
                        }
                        Rectangle {
                            visible: window.jelly
                            width: parent.current ? 8 : 6
                            height: width
                            radius: width / 2
                            x: window.tokens.uiPadCard - 2
                            anchors.verticalCenter: parent.verticalCenter
                            color: parent.current ? window.tokens.uiSelectDot : "transparent"
                            border.color: parent.current ? window.tokens.uiSelectDot : window.tokens.uiCardBorder
                            border.width: 1.5
                        }

                        Text {
                            id: tabText
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.left: parent.left
                            anchors.leftMargin: window.jelly ? window.tokens.uiPadCard + 14 : window.tokens.space
                            text: window.t(modelData.label)
                            color: window.jelly ? window.tokens.uiInk
                                : parent.current ? window.tokens.accentForeground : window.tokens.foreground
                            font.pixelSize: window.jelly ? window.tokens.uiFontLabel : window.tokens.fontBody
                            font.weight: window.jelly && parent.current ? Font.DemiBold : Font.Normal
                        }

                        Rectangle {
                            anchors.fill: parent
                            radius: parent.radius
                            color: "transparent"
                            border.color: window.jelly ? window.tokens.uiFocus : window.tokens.focus
                            border.width: parent.activeFocus ? 2 : 0
                        }

                        MouseArea {
                            id: tabArea
                            anchors.fill: parent
                            hoverEnabled: true
                            onClicked: window.page = modelData.id
                        }
                    }
                }

                Item { width: 1; height: window.tokens.spaceSection }

                Text {
                    width: parent.width
                    wrapMode: Text.WordWrap
                    text: window.client ? window.client.status : ""
                    color: window.client && window.client.online ? window.tokens.appInkMuted : window.tokens.appWarning
                    font.pixelSize: window.tokens.appFontCaption
                    leftPadding: window.jelly ? window.tokens.uiGap : 0
                }
            }
        }

        Loader {
            id: content
            anchors.left: sidebar.right
            anchors.right: parent.right
            anchors.top: window.jelly ? header.bottom : parent.top
            anchors.bottom: parent.bottom
            anchors.bottomMargin: window.jelly ? window.tokens.uiGap : 0
            sourceComponent: window.page === "plugins" ? pluginsPage
                : window.page === "history" ? historyPage
                : window.page === "personalization" ? personalizationPage
                : window.page === "ai" && window.conversation ? aiPage
                : compositionPage
        }

        /// Styled pages show how far they scroll: a slim bar at the right
        /// edge while there is more than fits (the wheel, PageUp/PageDown
        /// and Tab scroll; the bar itself takes no input).
        Rectangle {
            id: scrollBar
            objectName: "centersScrollBar"
            readonly property var flick: content.item
            readonly property bool overflow: !!flick && flick.contentHeight !== undefined && flick.contentHeight > flick.height + 1
            visible: window.jelly && overflow
            anchors.right: content.right
            anchors.rightMargin: 4
            y: content.y + 6 + (overflow ? (content.height - 12 - height) * Math.min(1, Math.max(0, flick.contentY / Math.max(1, flick.contentHeight - flick.height))) : 0)
            width: 4
            height: overflow ? Math.max(32, (content.height - 12) * flick.height / flick.contentHeight) : 0
            radius: 2
            color: window.jelly ? window.tokens.uiSeparator : "transparent"
            Accessible.ignored: true
        }
    }

    Component {
        id: compositionPage
        CompositionCenter {
            client: window.client
            tokens: window.tokens
        }
    }

    Component {
        id: pluginsPage
        PluginCenter {
            client: window.client
            tokens: window.tokens
        }
    }

    Component {
        id: historyPage
        HistoryCenter {
            client: window.client
            tokens: window.tokens
        }
    }

    Component {
        id: aiPage
        AISettings {
            client: window.client
            tokens: window.tokens
            conversation: window.conversation
        }
    }

    Component {
        id: personalizationPage
        PersonalizationCenter {
            client: window.client
            tokens: window.tokens
            providers: window.providers
        }
    }
}
