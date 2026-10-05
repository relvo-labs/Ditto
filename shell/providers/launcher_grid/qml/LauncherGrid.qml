import QtQuick
import Quickshell
import Quickshell.Wayland

/// Launcher A (`ui.launcher`): a full-screen grid of applications, one page per
/// category. Arrow keys move, PageUp/PageDown change the category, Enter
/// launches, Esc closes. The list comes from `desktop.launcher.list_apps`
/// (Core's index); applications start only through `desktop.launcher.launch`.
Scope {
    id: provider

    property var client: null
    property var tokens: null
    property var config: ({})
    property var screen: null
    property string slotName: ""
    property string entryId: ""
    property bool shown: false

    readonly property string reservedEdge: "none"
    property bool ready: false
    property bool isOpen: false
    property var apps: []
    property string status: ""
    property int categoryIndex: 0

    /// Main categories of the freedesktop menu specification, in page order.
    readonly property var mainCategories: ["AudioVideo", "Development", "Education", "Game", "Graphics", "Network", "Office", "Science", "Settings", "System", "Utility"]
    readonly property var categories: {
        const present = mainCategories.filter(name => apps.some(app => app.categories.indexOf(name) >= 0));
        return [""].concat(present);
    }
    readonly property var visibleApps: {
        const category = categories[Math.min(categoryIndex, categories.length - 1)] || "";
        const list = category === "" ? apps : apps.filter(app => app.categories.indexOf(category) >= 0);
        return list.slice().sort((left, right) => left.name.localeCompare(right.name));
    }

    function healthy() {
        return ready && client !== null && tokens !== null;
    }

    function release() {
        isOpen = false;
        shown = false;
    }

    function t(source) {
        return client ? client.t(source) : source;
    }

    function open() {
        if (!shown) {
            return;
        }
        isOpen = true;
        grid.currentIndex = 0;
        Qt.callLater(() => grid.forceActiveFocus());
        status = t(qsTr("正在讀取應用程式清單"));
        client.capability("desktop.launcher.list_apps", {}, function (result) {
            provider.apps = result.apps;
            provider.status = result.apps.length === 0 ? provider.t(qsTr("沒有找到應用程式")) : "";
        }, function (error) {
            provider.status = provider.t(qsTr("應用程式清單暫不可用"));
        });
    }

    function close() {
        isOpen = false;
    }

    function toggle() {
        if (isOpen) {
            close();
        } else {
            open();
        }
    }

    function launch(app) {
        if (!app) {
            return;
        }
        client.launchApp(app.app_id, function () {
            provider.close();
        }, function (error) {
            provider.status = provider.t(qsTr("無法啟動「%1」")).arg(app.name);
        });
    }

    function categoryLabel(name) {
        return name === "" ? t(qsTr("全部")) : client.key("category." + name, {});
    }

    Component.onCompleted: ready = true

    PanelWindow {
        id: surface

        visible: provider.shown && provider.isOpen
        anchors { top: true; bottom: true; left: true; right: true }
        exclusionMode: ExclusionMode.Ignore
        color: provider.tokens.scrim
        focusable: true
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: provider.isOpen ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
        WlrLayershell.namespace: "ditto-launcher-grid"

        MouseArea {
            anchors.fill: parent
            onClicked: provider.close()
        }

        FocusScope {
            id: body
            anchors.fill: parent
            anchors.margins: 72
            focus: true

            Keys.onEscapePressed: provider.close()
            Keys.onPressed: event => {
                if (event.key === Qt.Key_PageDown) {
                    provider.categoryIndex = (provider.categoryIndex + 1) % provider.categories.length;
                    grid.currentIndex = 0;
                    event.accepted = true;
                } else if (event.key === Qt.Key_PageUp) {
                    provider.categoryIndex = (provider.categoryIndex + provider.categories.length - 1) % provider.categories.length;
                    grid.currentIndex = 0;
                    event.accepted = true;
                }
            }

            Row {
                id: tabs
                anchors.top: parent.top
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: provider.tokens.space

                Repeater {
                    model: provider.categories

                    Rectangle {
                        required property var modelData
                        required property int index
                        width: tabLabel.implicitWidth + provider.tokens.spaceWide * 2
                        height: provider.tokens.controlHeight
                        radius: height / 2
                        color: index === provider.categoryIndex ? provider.tokens.accent : provider.tokens.surfaceStrong
                        Accessible.role: Accessible.PageTab
                        Accessible.name: tabLabel.text

                        Text {
                            id: tabLabel
                            anchors.centerIn: parent
                            text: provider.categoryLabel(modelData)
                            color: index === provider.categoryIndex ? provider.tokens.onAccent : provider.tokens.foreground
                            font.pixelSize: provider.tokens.fontBody
                        }

                        MouseArea {
                            anchors.fill: parent
                            onClicked: {
                                provider.categoryIndex = index;
                                grid.currentIndex = 0;
                            }
                        }
                    }
                }
            }

            Text {
                anchors.top: tabs.bottom
                anchors.topMargin: provider.tokens.space
                anchors.horizontalCenter: parent.horizontalCenter
                text: provider.status.length > 0 ? provider.status
                    : provider.t(qsTr("方向鍵選擇，Enter 開啟，PageUp／PageDown 換類別，Esc 關閉"))
                color: provider.tokens.foregroundMuted
                font.pixelSize: provider.tokens.fontSmall
            }

            GridView {
                id: grid
                anchors.fill: parent
                anchors.topMargin: tabs.height + provider.tokens.spaceSection * 2
                cellWidth: 150
                cellHeight: 120
                clip: true
                focus: true
                keyNavigationEnabled: true
                model: provider.visibleApps
                highlightMoveDuration: provider.tokens.durationFast
                Accessible.role: Accessible.List
                Accessible.name: provider.t(qsTr("應用程式"))

                Keys.onReturnPressed: provider.launch(provider.visibleApps[currentIndex])
                Keys.onEnterPressed: provider.launch(provider.visibleApps[currentIndex])

                delegate: Rectangle {
                    required property var modelData
                    required property int index
                    width: grid.cellWidth - provider.tokens.space
                    height: grid.cellHeight - provider.tokens.space
                    radius: provider.tokens.radiusMedium
                    color: GridView.isCurrentItem ? provider.tokens.surfaceStrong : "transparent"
                    border.color: GridView.isCurrentItem ? provider.tokens.focus : "transparent"
                    border.width: 2
                    Accessible.role: Accessible.Button
                    Accessible.name: modelData.name

                    Rectangle {
                        anchors.horizontalCenter: parent.horizontalCenter
                        y: provider.tokens.space
                        width: 48
                        height: 48
                        radius: 14
                        color: provider.tokens.accent
                        Text {
                            anchors.centerIn: parent
                            text: modelData.name.substring(0, 1)
                            color: provider.tokens.onAccent
                            font.pixelSize: provider.tokens.fontTitle
                            font.bold: true
                        }
                    }

                    Text {
                        anchors.bottom: parent.bottom
                        anchors.bottomMargin: provider.tokens.space
                        width: parent.width - provider.tokens.space * 2
                        anchors.horizontalCenter: parent.horizontalCenter
                        horizontalAlignment: Text.AlignHCenter
                        elide: Text.ElideRight
                        text: modelData.name
                        color: provider.tokens.foreground
                        font.pixelSize: provider.tokens.fontBody
                    }

                    MouseArea {
                        anchors.fill: parent
                        onClicked: provider.launch(modelData)
                    }
                }
            }
        }
    }
}
