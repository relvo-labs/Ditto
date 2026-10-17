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
    implicitHeight: 740
    minimumSize: Qt.size(760, 520)
    color: tokens ? tokens.background : "#12121a"
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
        } else {
            Qt.callLater(recoverFocus);
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

        Rectangle {
            id: sidebar
            width: 200
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            color: window.tokens.surfaceStrong

            Column {
                anchors.fill: parent
                anchors.margins: window.tokens.spaceWide
                spacing: window.tokens.spaceTight

                Text {
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
                        height: window.tokens.controlHeight + 4
                        radius: window.tokens.radiusSmall
                        color: current ? window.tokens.accent : (tabArea.containsMouse ? window.tokens.surface : "transparent")
                        activeFocusOnTab: true
                        Accessible.role: Accessible.PageTab
                        Accessible.name: tabText.text
                        Accessible.selected: current
                        Keys.onReturnPressed: window.page = modelData.id
                        Keys.onSpacePressed: window.page = modelData.id

                        Text {
                            id: tabText
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.left: parent.left
                            anchors.leftMargin: window.tokens.space
                            text: window.t(modelData.label)
                            color: parent.current ? window.tokens.accentForeground : window.tokens.foreground
                            font.pixelSize: window.tokens.fontBody
                        }

                        Rectangle {
                            anchors.fill: parent
                            radius: parent.radius
                            color: "transparent"
                            border.color: window.tokens.focus
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
                    color: window.client && window.client.online ? window.tokens.foregroundMuted : window.tokens.warning
                    font.pixelSize: window.tokens.fontSmall
                }
            }
        }

        Loader {
            id: content
            anchors.left: sidebar.right
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            sourceComponent: window.page === "plugins" ? pluginsPage
                : window.page === "history" ? historyPage
                : window.page === "personalization" ? personalizationPage
                : window.page === "ai" && window.conversation ? aiPage
                : compositionPage
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
