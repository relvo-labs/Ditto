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
    property string page: "composition"
    signal closeRequested()

    function t(source) {
        return client ? client.t(source) : source;
    }

    readonly property var pages: [
        { id: "composition", label: qsTr("組合中心") },
        { id: "plugins", label: qsTr("插件中心") },
        { id: "history", label: qsTr("變更紀錄") },
        { id: "personalization", label: qsTr("個人化設定") }
    ]

    title: t(qsTr("Ditto 設定"))
    implicitWidth: 1080
    implicitHeight: 740
    minimumSize: Qt.size(760, 520)
    color: tokens ? tokens.background : "#12121a"
    visible: true
    onClosed: window.closeRequested()

    Item {
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
                            color: parent.current ? window.tokens.onAccent : window.tokens.foreground
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
        id: personalizationPage
        PersonalizationCenter {
            client: window.client
            tokens: window.tokens
            providers: window.providers
        }
    }
}
