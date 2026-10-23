import QtQuick
import Quickshell
import Quickshell.Wayland

/// Dock A (`ui.dock`): a bottom-centred row of the running windows. Its data is
/// `client.windows` only — the running list, nothing pinned — which is what
/// makes it a different provider from the pill dock, not a restyle.
///
/// Each window is shown the way a person recognises it: the application's own
/// icon and the window's title, not the compositor's app id. Name and icon
/// come from the desktop entry (`desktop.launcher.list_apps`, read when the
/// Dock is shown); an application the index does not know gets a lettered
/// squircle and a name derived from its id. The window in use has a raised
/// plate, bold text and a bar under it, so it is not told by colour alone; a
/// minimised window has a faded icon and muted text (no italic: CJK has none)
/// and a window on another workspace carries a "workspace N" chip. The close button appears under the pointer or keyboard
/// focus only, so it is not one stray click away on every tile.
Scope {
    id: provider

    property var client: null
    property var tokens: null
    property var config: ({})
    property var screen: null
    property string slotName: ""
    property string entryId: ""
    property bool shown: false

    readonly property string reservedEdge: "bottom"
    property bool ready: false
    property var apps: []
    property bool appsLoaded: false

    function healthy() {
        return ready && client !== null && tokens !== null;
    }

    function release() {
        shown = false;
    }

    function t(source) {
        return client ? client.t(source) : source;
    }

    // ---- application identity ---------------------------------------------
    function loadApps() {
        if (!client || appsLoaded || typeof client.capability !== "function") return;
        client.capability("desktop.launcher.list_apps", {}, function (result) {
            provider.apps = result && Array.isArray(result.apps) ? result.apps : [];
            provider.appsLoaded = true;
        }, function (error) {
            provider.appsLoaded = false;
        });
    }

    /// Forms an app id is commonly reported in: as is, its last reverse-DNS
    /// segment (`foot` ↔ `org.codeberg.dnkl.foot`) and, for a snap, the part
    /// before `_` (`telegram-desktop_telegram-desktop`).
    function idForms(appId) {
        const id = String(appId).toLowerCase();
        const forms = [id, id.split(".").pop()];
        if (id.indexOf("_") > 0) forms.push(id.split("_")[0]);
        return forms;
    }

    function appFor(appId) {
        if (!appId) return null;
        const wanted = idForms(appId);
        return apps.find(app => String(app.app_id).toLowerCase() === wanted[0])
            || apps.find(app => idForms(app.app_id).some(form => wanted.indexOf(form) >= 0))
            || null;
    }

    /// The Shell's own windows (settings, conversation) are Quickshell's.
    function ownWindow(appId) {
        return String(appId).toLowerCase() === "org.quickshell";
    }

    /// A readable name when the index has none: `org.example.photo-viewer`
    /// becomes "Photo viewer". A Chrome web app's id is an opaque hash.
    function fallbackName(appId) {
        const id = String(appId || "");
        if (id.length === 0) return t(qsTr("未命名應用程式"));
        if (/^chrome-[a-p]{32}/.test(id)) return t(qsTr("網頁應用程式"));
        let base = id.indexOf("_") > 0 ? id.split("_")[0] : id;
        base = base.split(".").pop().replace(/[-_]+/g, " ").trim();
        return base.length > 0 ? base.charAt(0).toUpperCase() + base.slice(1) : id;
    }

    function appName(appId) {
        if (ownWindow(appId)) return "Ditto";
        const app = appFor(appId);
        return app && app.name ? String(app.name) : fallbackName(appId);
    }

    function iconSource(appId) {
        const app = appFor(appId);
        const icon = app && app.icon ? String(app.icon) : "";
        if (icon.length === 0) return "";
        if (icon.charAt(0) === "/") return "file://" + icon;
        return Quickshell.iconPath(icon, true);
    }

    /// The title without a trailing " - <application name>", which the icon
    /// already says; an empty title falls back to the application's name.
    function windowLabel(window) {
        const name = appName(window.app_id);
        let title = String(window.title || "").trim();
        for (const separator of [" - ", " — ", " – "]) {
            const suffix = separator + name;
            if (title.length > suffix.length && title.endsWith(suffix)) {
                title = title.slice(0, title.length - suffix.length).trim();
                break;
            }
        }
        return title.length > 0 ? title : name;
    }

    /// The workspace's name when the window is not on the active one.
    function otherWorkspace(window) {
        const list = client && Array.isArray(client.workspaces) ? client.workspaces : [];
        if (list.length < 2 || !window.workspace_id) return "";
        const workspace = list.find(item => item.id === window.workspace_id);
        return workspace && !workspace.active ? String(workspace.name || workspace.id) : "";
    }

    function accessibleName(window) {
        const name = appName(window.app_id);
        const label = windowLabel(window);
        const workspace = otherWorkspace(window);
        return (label === name ? name : t(qsTr("%1：%2")).arg(name).arg(label))
            + (window.focused ? t(qsTr("（作用中）")) : "")
            + (window.state === "minimized" ? t(qsTr("（已最小化）")) : "")
            + (workspace ? t(qsTr("（工作區 %1）")).arg(workspace) : "");
    }

    /// Squircle fills in the lavender family; white initials stay ≥4.5:1.
    readonly property var fallbackFills: [["#7c66e4", "#5c46cc"], ["#9468d8", "#7046bc"], ["#6878e0", "#4a5ac4"],
                                          ["#a865aa", "#86438c"], ["#4f80c2", "#365e9e"]]
    function fallbackFill(appId) {
        let hash = 0;
        const text = String(appId);
        for (let i = 0; i < text.length; i++) hash = (hash * 31 + text.charCodeAt(i)) % 100003;
        return fallbackFills[hash % fallbackFills.length];
    }

    // ---- geometry -----------------------------------------------------------
    readonly property int iconSize: 22
    readonly property int tileHeight: 40
    readonly property int tileMinWidth: 120
    readonly property int tileMaxWidth: 240
    readonly property int barPadding: 6
    readonly property int edgeGap: 8
    readonly property int thickness: tileHeight + barPadding * 2 + edgeGap
    // Centre of the visible bar, excluding the transparent edge gap.
    readonly property var edgeGeometry: ({
        version: 1, output: dock.screen ? dock.screen.name : "", edge: reservedEdge,
        visible: dock.visible, centreInset: edgeGap + (tileHeight + barPadding * 2) / 2
    })
    readonly property real screenWidth: screen && screen.width > 0 ? screen.width : 1280
    /// Tiles shrink (down to the minimum, then elide) so the row fits the screen.
    readonly property int tileWidth: {
        const count = Math.max(1, tileModel.count);
        const spacing = tokens ? tokens.spaceTight : 4;
        const available = screenWidth - 2 * (edgeGap + barPadding) - 96 - spacing * (count - 1);
        return Math.max(tileMinWidth, Math.min(tileMaxWidth, Math.floor(available / count)));
    }

    // Presentation-only projection: window updates must not reset input.
    readonly property var windows: client ? client.windows : []
    ListModel { id: tileModel; dynamicRoles: true }
    function syncTiles() {
        if (!ready) return;
        for (let i = tileModel.count - 1; i >= 0; --i) {
            if (!windows.some(window => window.id === tileModel.get(i).key)) tileModel.remove(i);
        }
        for (let i = 0; i < windows.length; ++i) {
            let found = i;
            while (found < tileModel.count && tileModel.get(found).key !== windows[i].id) ++found;
            if (found === tileModel.count) {
                tileModel.insert(i, { key: windows[i].id, entryData: windows[i] });
            } else {
                if (found !== i) tileModel.move(found, i, 1);
                if (JSON.stringify(tileModel.get(i).entryData) !== JSON.stringify(windows[i]))
                    tileModel.setProperty(i, "entryData", windows[i]);
            }
        }
    }
    onWindowsChanged: syncTiles()
    onShownChanged: if (shown) loadApps()
    Component.onCompleted: { ready = true; syncTiles(); if (shown) loadApps(); }

    PanelWindow {
        id: dock

        visible: provider.shown
        screen: provider.screen
        anchors { bottom: true }
        implicitWidth: Math.max(220, bar.width + provider.edgeGap * 2)
        implicitHeight: provider.thickness
        exclusiveZone: provider.shown ? provider.thickness : 0
        color: "transparent"
        // Mapped without keyboard interactivity, then on demand: a surface
        // that maps on demand is given the keyboard focus by the compositor,
        // so swapping a Dock would take focus from the window in use.
        property bool mapped: false
        onVisibleChanged: if (!visible) mapped = false
        Timer {
            interval: 250
            running: dock.visible && !dock.mapped
            onTriggered: dock.mapped = true
        }
        WlrLayershell.keyboardFocus: mapped ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None
        WlrLayershell.namespace: "ditto-dock-bottom"

        Rectangle {
            id: bar
            objectName: "dockBar"
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            anchors.bottomMargin: provider.edgeGap
            width: entries.implicitWidth + provider.barPadding * 2
            height: provider.tileHeight + provider.barPadding * 2
            radius: provider.tokens.radiusLarge
            color: provider.tokens.surface
            border.color: provider.tokens.border
            border.width: 1
            opacity: provider.tokens.surfaceOpacity
        }

        Row {
            id: entries
            anchors.centerIn: bar
            spacing: provider.tokens.spaceTight

            Repeater {
                model: tileModel

                Rectangle {
                    id: tile
                    required property var entryData
                    readonly property var modelData: entryData
                    readonly property bool current: modelData.focused === true
                    readonly property bool minimized: modelData.state === "minimized"
                    readonly property bool hovered: tileHover.hovered
                    readonly property bool canClose: provider.client !== null
                        && typeof provider.client.capabilityAvailable === "function"
                        && provider.client.capabilityAvailable("desktop.windows.close_request")
                    readonly property string workspace: provider.otherWorkspace(modelData)

                    objectName: "dockWindow_" + modelData.id
                    width: provider.tileWidth
                    height: provider.tileHeight
                    radius: provider.tokens.radiusMedium
                    color: current ? provider.tokens.surfaceStrong
                        : hovered ? Qt.rgba(provider.tokens.surfaceStrong.r, provider.tokens.surfaceStrong.g,
                                            provider.tokens.surfaceStrong.b, 0.6)
                        : "transparent"
                    border.color: current ? provider.tokens.border : "transparent"
                    border.width: 1
                    activeFocusOnTab: true
                    Accessible.role: Accessible.Button
                    Accessible.name: provider.accessibleName(modelData)
                    Accessible.onPressAction: provider.client.focusWindow(modelData.id)

                    /// The whole tile, close button included, is one hover target.
                    HoverHandler { id: tileHover }

                    MouseArea {
                        id: area
                        anchors.fill: parent
                        z: -1
                        onClicked: provider.client.focusWindow(tile.modelData.id)
                    }

                    Item {
                        id: iconBox
                        objectName: "dockWindowIcon"
                        anchors.left: parent.left
                        anchors.leftMargin: provider.tokens.space
                        anchors.verticalCenter: parent.verticalCenter
                        width: provider.iconSize
                        height: provider.iconSize
                        opacity: tile.minimized ? 0.55 : 1

                        Image {
                            id: icon
                            objectName: "dockWindowIconImage"
                            anchors.fill: parent
                            source: provider.iconSource(tile.modelData.app_id)
                            sourceSize.width: provider.iconSize * 2
                            sourceSize.height: provider.iconSize * 2
                            fillMode: Image.PreserveAspectFit
                            asynchronous: true
                            smooth: true
                            visible: status === Image.Ready
                        }

                        /// No usable icon: a squircle with the name's first letter.
                        Rectangle {
                            id: fallbackIcon
                            objectName: "dockWindowIconFallback"
                            anchors.fill: parent
                            visible: icon.status !== Image.Ready
                            radius: Math.round(width * 0.3)
                            readonly property var fill: provider.fallbackFill(tile.modelData.app_id)
                            gradient: Gradient {
                                GradientStop { position: 0.0; color: fallbackIcon.fill[0] }
                                GradientStop { position: 1.0; color: fallbackIcon.fill[1] }
                            }
                            Text {
                                anchors.centerIn: parent
                                text: {
                                    const name = String(provider.appName(tile.modelData.app_id)).trim();
                                    return name.length > 0 ? name.charAt(0).toUpperCase() : "?";
                                }
                                color: "#ffffff"
                                font.pixelSize: 12
                                font.weight: Font.DemiBold
                            }
                        }
                    }

                    Text {
                        id: label
                        objectName: "dockWindowLabel"
                        anchors.left: iconBox.right
                        anchors.leftMargin: provider.tokens.space
                        anchors.right: chip.visible ? chip.left : closeSlot.left
                        anchors.rightMargin: provider.tokens.spaceTight
                        anchors.verticalCenter: parent.verticalCenter
                        elide: Text.ElideRight
                        maximumLineCount: 1
                        text: provider.windowLabel(tile.modelData)
                        color: tile.minimized ? provider.tokens.foregroundMuted : provider.tokens.foreground
                        font.pixelSize: provider.tokens.fontBody
                        font.weight: tile.current ? Font.DemiBold : Font.Normal
                    }

                    /// On another workspace: that workspace's name.
                    Rectangle {
                        id: chip
                        objectName: "dockWindowWorkspace"
                        visible: tile.workspace.length > 0
                        anchors.right: closeSlot.left
                        anchors.rightMargin: provider.tokens.spaceTight
                        anchors.verticalCenter: parent.verticalCenter
                        width: chipText.implicitWidth + 12
                        height: 20
                        radius: 10
                        color: provider.tokens.surfaceStrong
                        border.color: provider.tokens.border
                        border.width: 1
                        Text {
                            id: chipText
                            anchors.centerIn: parent
                            text: provider.t(qsTr("工作區 %1")).arg(tile.workspace)
                            color: provider.tokens.foreground
                            font.pixelSize: provider.tokens.fontSmall
                        }
                    }

                    /// Space for the close button, kept so labels do not jump.
                    Item {
                        id: closeSlot
                        anchors.right: parent.right
                        anchors.rightMargin: provider.tokens.spaceTight
                        anchors.verticalCenter: parent.verticalCenter
                        width: tile.canClose ? 24 : 0
                        height: 24

                        Rectangle {
                            id: closeButton
                            objectName: "dockWindowClose"
                            anchors.fill: parent
                            radius: width / 2
                            // An action the compositor cannot perform is not
                            // shown as a button that would only fail.
                            visible: tile.canClose && (tile.hovered || tile.activeFocus)
                            color: closeArea.containsMouse ? provider.tokens.border : "transparent"
                            Accessible.role: Accessible.Button
                            Accessible.name: provider.t(qsTr("關閉"))
                            Text {
                                anchors.centerIn: parent
                                text: "✕"
                                color: provider.tokens.foregroundMuted
                                font.pixelSize: provider.tokens.fontSmall
                            }
                            MouseArea {
                                id: closeArea
                                anchors.fill: parent
                                hoverEnabled: true
                                enabled: tile.canClose
                                onClicked: provider.client.closeWindow(tile.modelData.id)
                            }
                        }
                    }

                    /// The window in use: a bar under the tile (shape, not only colour).
                    Rectangle {
                        objectName: "dockWindowIndicator"
                        visible: tile.current
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.bottom: parent.bottom
                        anchors.bottomMargin: 4
                        width: 18
                        height: 3
                        radius: 1.5
                        color: provider.tokens.focus
                    }

                    /// Keyboard focus ring.
                    Rectangle {
                        anchors.fill: parent
                        anchors.margins: -2
                        radius: parent.radius + 2
                        color: "transparent"
                        border.color: provider.tokens.focus
                        border.width: parent.activeFocus ? 2 : 0
                    }

                    Keys.onReturnPressed: provider.client.focusWindow(modelData.id)
                    Keys.onSpacePressed: provider.client.focusWindow(modelData.id)
                    Keys.onDeletePressed: if (canClose) provider.client.closeWindow(modelData.id)
                }
            }

            Text {
                visible: !provider.client || provider.client.windows.length === 0
                height: provider.tileHeight
                verticalAlignment: Text.AlignVCenter
                leftPadding: provider.tokens.space
                rightPadding: provider.tokens.space
                color: provider.tokens.foregroundMuted
                font.pixelSize: provider.tokens.fontBody
                text: provider.client && provider.client.online
                    ? provider.t(qsTr("目前沒有執行中的視窗"))
                    : (provider.client ? provider.client.status : "")
            }
        }
    }
}
