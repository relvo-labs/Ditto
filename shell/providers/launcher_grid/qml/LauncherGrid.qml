pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Wayland

/// Launcher A (`ui.launcher`): a full-screen grid of applications, one page per
/// category, with cross-category search ranked by Core's launcher index.
/// Query, selection and request generations are transient Shell state.
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
    property var results: []
    property int generation: 0
    property int session: 0
    property string listStatus: ""
    readonly property bool searching: query.text.trim().length > 0

    /// Main categories of the freedesktop menu specification, in page order.
    readonly property var mainCategories: ["AudioVideo", "Development", "Education", "Game", "Graphics", "Network", "Office", "Science", "Settings", "System", "Utility"]
    readonly property var categories: {
        if (searching) return [""];
        const present = mainCategories.filter(name => apps.some(app => app.categories.indexOf(name) >= 0));
        return [""].concat(present);
    }
    readonly property var visibleApps: {
        if (searching) return results;
        const category = categories[Math.min(categoryIndex, categories.length - 1)] || "";
        const list = category === "" ? apps : apps.filter(app => app.categories.indexOf(category) >= 0);
        return list.slice().sort((left, right) => left.name.localeCompare(right.name));
    }

    function healthy() {
        return ready && client !== null && tokens !== null;
    }

    function release() {
        close();
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
        session += 1;
        generation += 1;
        const mine = session;
        query.text = "";
        apps = [];
        results = [];
        categoryIndex = 0;
        Qt.callLater(() => { if (provider.isOpen) query.forceActiveFocus(); });
        listStatus = t(qsTr("正在讀取應用程式清單"));
        status = listStatus;
        client.capability("desktop.launcher.list_apps", {}, function (result) {
            if (mine !== provider.session || !provider.isOpen) return;
            provider.apps = result.apps;
            provider.listStatus = result.apps.length === 0 ? provider.t(qsTr("沒有找到應用程式")) : "";
            if (!provider.searching) provider.status = provider.listStatus;
        }, function (error) {
            if (mine !== provider.session || !provider.isOpen) return;
            provider.listStatus = provider.t(qsTr("應用程式清單暫不可用；請關閉後重新開啟。"));
            if (!provider.searching) provider.status = provider.listStatus;
        });
    }

    function close() {
        isOpen = false;
        session += 1;
        generation += 1;
    }

    function search(text) {
        generation += 1;
        const mine = generation;
        results = [];
        if (!isOpen) return;
        if (text.trim().length === 0) {
            status = listStatus;
            return;
        }
        categoryIndex = 0;
        status = t(qsTr("正在搜尋應用程式"));
        client.capability("desktop.launcher.search", { query: text, limit: 200 }, function (result) {
            if (mine !== provider.generation || !provider.isOpen) return;
            provider.results = result.apps;
            provider.status = result.apps.length === 0 ? provider.t(qsTr("沒有符合的應用程式")) : "";
        }, function (error) {
            if (mine !== provider.generation || !provider.isOpen) return;
            provider.status = provider.t(qsTr("搜尋暫不可用；請修改搜尋文字後重試。"));
        });
    }

    function clearOrClose() {
        if (query.text.length > 0) {
            query.text = "";
            query.forceActiveFocus();
        } else {
            close();
        }
    }

    function handleKey(event) {
        if (query.inputMethodComposing) return;
        const columns = Math.max(1, Math.floor(grid.width / grid.cellWidth));
        let step = 0;
        if (event.key === Qt.Key_Left) step = -1;
        else if (event.key === Qt.Key_Right) step = 1;
        else if (event.key === Qt.Key_Up) step = -columns;
        else if (event.key === Qt.Key_Down) step = columns;
        else if (event.key === Qt.Key_Escape) clearOrClose();
        else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) launch(visibleApps[grid.currentIndex]);
        else if (event.key === Qt.Key_PageDown || event.key === Qt.Key_PageUp) {
            const direction = event.key === Qt.Key_PageDown ? 1 : -1;
            categoryIndex = (categoryIndex + categories.length + direction) % categories.length;
            grid.currentIndex = 0;
        } else return;
        if (step !== 0 && visibleApps.length > 0) {
            grid.currentIndex = Math.max(0, Math.min(visibleApps.length - 1, grid.currentIndex + step));
            grid.positionViewAtIndex(grid.currentIndex, GridView.Contain);
        }
        event.accepted = true;
    }

    function iconSource(icon) {
        if (!icon) return "";
        const name = String(icon);
        if (name.charAt(0) === "/") return "file://" + name;
        return Quickshell.iconPath(name, true);
    }

    function iconFallback(source, imageStatus) {
        return String(source).length === 0 || imageStatus !== Image.Ready;
    }

    onVisibleAppsChanged: grid.currentIndex = visibleApps.length > 0 ? 0 : -1

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

        // NFR-02: the first frame after opening, marked on the Shell's
        // counter (when it traces) so input → visible can be measured.
        property bool framed: false
        onVisibleChanged: if (!visible) framed = false
        Connections {
            target: body.Window.window
            function onFrameSwapped() {
                if (surface.visible && !surface.framed) {
                    surface.framed = true;
                    if (provider.client && provider.client.counter)
                        provider.client.counter.mark("launcher.frame");
                }
            }
        }

        MouseArea {
            anchors.fill: parent
            onClicked: provider.close()
        }

        FocusScope {
            id: body
            anchors.fill: parent
            anchors.margins: 72
            focus: true

            Keys.onPressed: event => provider.handleKey(event)

            Rectangle {
                id: searchBox
                anchors.top: parent.top
                anchors.horizontalCenter: parent.horizontalCenter
                width: Math.min(560, parent.width)
                height: provider.tokens.controlHeight
                radius: provider.tokens.radiusMedium
                color: provider.tokens.surfaceStrong
                border.color: query.activeFocus ? provider.tokens.focus : provider.tokens.border
                border.width: query.activeFocus ? 2 : 1

                TextInput {
                    id: query
                    objectName: "launcherGridQuery"
                    anchors.fill: parent
                    anchors.leftMargin: provider.tokens.spaceWide
                    anchors.rightMargin: provider.tokens.spaceWide
                    verticalAlignment: TextInput.AlignVCenter
                    color: provider.tokens.foreground
                    font.pixelSize: provider.tokens.fontBody
                    selectByMouse: true
                    clip: true
                    Accessible.role: Accessible.EditableText
                    Accessible.name: provider.t(qsTr("搜尋應用程式"))
                    onTextChanged: provider.search(text)
                    Keys.onPressed: event => provider.handleKey(event)

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: query.text.length === 0
                        text: provider.t(qsTr("輸入應用程式名稱"))
                        color: provider.tokens.foregroundMuted
                        font.pixelSize: provider.tokens.fontBody
                    }
                }
            }

            Row {
                id: tabs
                anchors.top: searchBox.bottom
                anchors.topMargin: provider.tokens.space
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: provider.tokens.space

                Repeater {
                    model: provider.categories

                    Rectangle {
                        id: categoryTab
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
                            text: provider.categoryLabel(categoryTab.modelData)
                            color: categoryTab.index === provider.categoryIndex ? provider.tokens.accentForeground : provider.tokens.foreground
                            font.pixelSize: provider.tokens.fontBody
                        }

                        MouseArea {
                            anchors.fill: parent
                            onClicked: {
                                provider.categoryIndex = categoryTab.index;
                                grid.currentIndex = 0;
                                query.forceActiveFocus();
                            }
                        }
                    }
                }
            }

            Text {
                id: hint
                anchors.top: tabs.bottom
                anchors.topMargin: provider.tokens.space
                anchors.horizontalCenter: parent.horizontalCenter
                text: provider.status.length > 0 ? provider.status
                    : provider.searching ? provider.t(qsTr("方向鍵選擇，Enter 開啟，Esc 清除搜尋，再按一次關閉"))
                    : provider.t(qsTr("方向鍵選擇，Enter 開啟，PageUp／PageDown 換類別，Esc 關閉"))
                color: provider.tokens.foregroundMuted
                font.pixelSize: provider.tokens.fontSmall
            }

            GridView {
                id: grid
                objectName: "launcherGridApps"
                anchors { top: hint.bottom; bottom: parent.bottom; left: parent.left; right: parent.right }
                anchors.topMargin: provider.tokens.spaceSection
                cellWidth: 150
                cellHeight: 120
                clip: true
                keyNavigationEnabled: false
                model: provider.visibleApps
                highlightMoveDuration: provider.tokens.durationFast
                Accessible.role: Accessible.List
                Accessible.name: provider.t(qsTr("應用程式"))

                delegate: Rectangle {
                    id: tile
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
                    Accessible.selected: GridView.isCurrentItem

                    Rectangle {
                        id: iconTile
                        anchors.horizontalCenter: parent.horizontalCenter
                        y: provider.tokens.space
                        width: 48
                        height: 48
                        radius: 14
                        color: fallback.visible ? provider.tokens.accent : "transparent"
                        Image {
                            id: appIcon
                            objectName: "launcherGridIcon"
                            anchors.fill: parent
                            source: provider.iconSource(tile.modelData.icon)
                            sourceSize: Qt.size(48, 48)
                            fillMode: Image.PreserveAspectFit
                            visible: !provider.iconFallback(source, status)
                        }
                        Text {
                            id: fallback
                            objectName: "launcherGridIconFallback"
                            anchors.centerIn: parent
                            visible: provider.iconFallback(appIcon.source, appIcon.status)
                            text: tile.modelData.name.substring(0, 1)
                            color: provider.tokens.accentForeground
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
                        text: tile.modelData.name
                        color: provider.tokens.foreground
                        font.pixelSize: provider.tokens.fontBody
                    }

                    MouseArea {
                        anchors.fill: parent
                        onClicked: provider.launch(tile.modelData)
                    }
                }
            }
        }
    }
}
