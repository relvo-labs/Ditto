pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Wayland

/// Dock B (`ui.dock`): a floating capsule, centred on the bottom edge or on
/// the left, with the pinned applications and the running windows as icons.
/// Its data is `desktop.launcher.list_apps` plus `client.windows`; the pinned
/// list lives in this entry's `config` (`pinned`, `position`), so it survives
/// a swap to another dock and back. Pinning is a ChangeSet on that config,
/// like any other write.
///
/// Icons are the applications' own: the desktop entry's `Icon` (a theme name
/// resolved through the icon theme, or an absolute path). An application
/// without a usable icon shows a lettered tile with its name, so it is never
/// a blank button. The window in use has a bar under its icon and a running
/// one a dot; the accessible name says the same in words. Only the capsule
/// takes input: the transparent margin around it lets clicks through.
Scope {
    id: provider

    property var client: null
    property var tokens: null
    property var config: ({})
    property var screen: null
    property string slotName: ""
    property string entryId: ""
    property bool shown: false

    readonly property string position: config && config.position === "left" ? "left" : "bottom"
    readonly property string reservedEdge: position
    readonly property var pinned: config && Array.isArray(config.pinned) ? config.pinned : ["firefox", "org.codeberg.dnkl.foot", "org.kde.kate"]
    property bool ready: false
    property var apps: []
    property bool appsLoaded: false
    property string notice: ""

    readonly property int iconSize: 42
    readonly property int tileSize: 52
    readonly property int pillPadding: 8
    /// Space between the capsule and the screen edge.
    readonly property int edgeGap: 12
    readonly property int pillThickness: tileSize + pillPadding * 2
    readonly property int thickness: pillThickness + edgeGap + 4

    function healthy() {
        return ready && client !== null && tokens !== null;
    }

    function release() {
        shown = false;
    }

    function t(source) {
        return client ? client.t(source) : source;
    }

    /// The window of an application, matched by app id (a desktop id may
    /// carry a reverse-DNS prefix the window's app id lacks, or the reverse).
    function windowOf(appId) {
        if (!client) {
            return null;
        }
        const wanted = String(appId).toLowerCase();
        const tail = wanted.split(".").pop();
        return client.windows.find(item => {
            const id = String(item.app_id).toLowerCase();
            return id === wanted || id === tail || id.split(".").pop() === tail;
        }) || null;
    }

    /// The indexed application for an id: the same id, or else the same
    /// last segment (a window's `foot` is the index's `org.codeberg.dnkl.foot`).
    function appFor(appId) {
        const wanted = String(appId).toLowerCase();
        const tail = wanted.split(".").pop();
        return apps.find(item => String(item.app_id).toLowerCase() === wanted)
            || apps.find(item => String(item.app_id).toLowerCase().split(".").pop() === tail)
            || null;
    }

    function appName(appId) {
        const app = appFor(appId);
        return app ? app.name : appId;
    }

    /// The image for an application's icon, or "" when it has none the
    /// icon theme can resolve (the lettered tile is shown instead).
    function iconSource(appId) {
        const app = appFor(appId);
        const icon = app && app.icon ? String(app.icon) : "";
        if (icon.length === 0) {
            return "";
        }
        if (icon.charAt(0) === "/") {
            return "file://" + icon;
        }
        return Quickshell.iconPath(icon, true);
    }

    function accessibleName(entry) {
        const running = !!entry.window;
        const current = running && entry.window.focused === true;
        return appName(entry.appId)
            + (current ? t(qsTr("（使用中）")) : running ? t(qsTr("（執行中）")) : "")
            + (entry.pinned ? t(qsTr("（已釘選）")) : "");
    }

    /// Pinned applications the index knows (or that are running), then the
    /// other running windows. A pinned id the index does not know is kept in
    /// the config but not shown as a button that could only fail.
    readonly property var entries: {
        const list = pinned
            .map(appId => ({ appId: appId, pinned: true, window: windowOf(appId) }))
            .filter(entry => entry.window || !appsLoaded || apps.some(app => app.app_id === entry.appId));
        if (client) {
            for (const window of client.windows) {
                if (!list.some(entry => entry.window && entry.window.id === window.id)) {
                    list.push({ appId: window.app_id, pinned: false, window: window });
                }
            }
        }
        return list;
    }

    function activate(entry) {
        if (entry.window) {
            client.focusWindow(entry.window.id);
        } else {
            client.launchApp(entry.appId, null, function (error) {
                provider.notice = provider.t(qsTr("無法啟動「%1」")).arg(provider.appName(entry.appId));
            });
        }
    }

    function togglePin(entry) {
        const next = entry.pinned ? pinned.filter(appId => appId !== entry.appId) : pinned.concat([entry.appId]);
        const after = Object.assign({}, config || {}, { pinned: next });
        client.propose([{ op: "set_entry_config", entry_id: entryId, after: after }], { surface: "dock" }, function (record) {
            provider.notice = record.result === "succeeded" ? "" : provider.t(qsTr("釘選沒有變更"));
        }, function (error) {
            provider.notice = client.errorText(error);
        });
    }

    function loadApps() {
        if (!client || appsLoaded) {
            return;
        }
        client.capability("desktop.launcher.list_apps", {}, function (result) {
            provider.apps = result.apps;
            provider.appsLoaded = true;
        }, function (error) {
            provider.appsLoaded = false;
        });
    }

    onShownChanged: if (shown) loadApps()
    Component.onCompleted: ready = true

    PanelWindow {
        id: dock

        readonly property bool vertical: provider.position === "left"

        visible: provider.shown
        anchors {
            bottom: provider.position === "bottom"
            left: provider.position === "left"
        }
        implicitWidth: vertical ? provider.thickness : pill.width + provider.edgeGap * 2
        implicitHeight: vertical ? pill.height + provider.edgeGap * 2 : provider.thickness
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
        WlrLayershell.namespace: "ditto-dock-pill"

        /// Input only on the capsule; the margin and shadow pass clicks on.
        mask: Region {
            item: pill
        }

        Item {
            id: pill
            objectName: "dockCapsule"
            width: dock.vertical ? provider.pillThickness : strip.implicitWidth + provider.pillPadding * 2 + provider.tokens.space * 2
            height: dock.vertical ? strip.implicitHeight + provider.pillPadding * 2 + provider.tokens.space * 2 : provider.pillThickness
            anchors.horizontalCenter: dock.vertical ? undefined : parent.horizontalCenter
            anchors.bottom: dock.vertical ? undefined : parent.bottom
            anchors.bottomMargin: provider.edgeGap
            anchors.verticalCenter: dock.vertical ? parent.verticalCenter : undefined
            anchors.left: dock.vertical ? parent.left : undefined
            anchors.leftMargin: provider.edgeGap
            readonly property real radius: Math.min(width, height) / 2

            /// Soft shadow from stacked translucent shapes (no shader); none
            /// in the low-power style.
            Repeater {
                model: provider.tokens.shadowEnabled ? [0.30, 0.16, 0.07] : []

                Rectangle {
                    required property real modelData
                    required property int index
                    readonly property real spread: (index + 1) * 3
                    anchors.fill: parent
                    anchors.margins: -spread
                    anchors.topMargin: 4 - spread
                    anchors.bottomMargin: -4 - spread
                    radius: pill.radius + spread
                    color: provider.tokens.shadowColor
                    opacity: modelData
                }
            }

            Rectangle {
                anchors.fill: parent
                radius: pill.radius
                color: provider.tokens.surface
                border.color: provider.tokens.border
                border.width: 1
                opacity: provider.tokens.surfaceOpacity
            }

            /// The bright inner edge (none with reduced transparency).
            Rectangle {
                anchors.fill: parent
                anchors.margins: 1
                radius: pill.radius - 1
                color: "transparent"
                border.color: provider.tokens.highlight !== undefined ? provider.tokens.highlight : "transparent"
                border.width: 1
            }

            Grid {
                id: strip
                anchors.centerIn: parent
                flow: dock.vertical ? Grid.TopToBottom : Grid.LeftToRight
                rows: dock.vertical ? Math.max(1, provider.entries.length + 1) : 1
                columns: dock.vertical ? 1 : Math.max(1, provider.entries.length + 1)
                spacing: provider.tokens.space
                verticalItemAlignment: Grid.AlignVCenter
                horizontalItemAlignment: Grid.AlignHCenter

                Repeater {
                    model: provider.entries

                    Item {
                        id: tile
                        required property var modelData
                        readonly property bool running: !!modelData.window
                        readonly property bool current: running && modelData.window.focused === true
                        objectName: "dockTile_" + modelData.appId
                        width: provider.tileSize
                        height: provider.tileSize
                        activeFocusOnTab: true
                        Accessible.role: Accessible.Button
                        Accessible.name: provider.accessibleName(modelData)
                        Accessible.onPressAction: provider.activate(modelData)

                        /// Plate behind the window in use, and under the pointer.
                        Rectangle {
                            anchors.fill: parent
                            radius: provider.tokens.radiusMedium
                            visible: tile.current || area.containsMouse
                            color: provider.tokens.surfaceStrong
                            border.color: provider.tokens.border
                            border.width: tile.current ? 1 : 0
                        }

                        Image {
                            id: icon
                            objectName: "dockIcon"
                            anchors.centerIn: parent
                            width: provider.iconSize
                            height: provider.iconSize
                            source: provider.iconSource(tile.modelData.appId)
                            sourceSize.width: provider.iconSize * 2
                            sourceSize.height: provider.iconSize * 2
                            fillMode: Image.PreserveAspectFit
                            asynchronous: true
                            smooth: true
                            visible: status === Image.Ready
                        }

                        /// Fallback: a lettered tile with the application's name.
                        Rectangle {
                            objectName: "dockIconFallback"
                            anchors.centerIn: parent
                            width: provider.iconSize
                            height: provider.iconSize
                            radius: provider.tokens.radiusMedium
                            visible: icon.status !== Image.Ready
                            color: provider.tokens.surfaceStrong
                            border.color: provider.tokens.border
                            border.width: 1

                            Text {
                                anchors.centerIn: parent
                                text: provider.appName(tile.modelData.appId).substring(0, 2)
                                color: provider.tokens.foreground
                                font.pixelSize: provider.tokens.fontBody
                                font.bold: true
                            }
                        }

                        /// Window in use: a bar. Running: a dot. Shape, not only
                        /// colour, tells them apart.
                        Rectangle {
                            objectName: "dockIndicator"
                            visible: tile.running
                            readonly property int length: tile.current ? 16 : 5
                            width: dock.vertical ? 4 : length
                            height: dock.vertical ? length : 4
                            radius: 2
                            color: tile.current ? provider.tokens.focus : provider.tokens.foregroundMuted
                            anchors.horizontalCenter: dock.vertical ? undefined : parent.horizontalCenter
                            anchors.bottom: dock.vertical ? undefined : parent.bottom
                            anchors.bottomMargin: 1
                            anchors.verticalCenter: dock.vertical ? parent.verticalCenter : undefined
                            anchors.left: dock.vertical ? parent.left : undefined
                            anchors.leftMargin: 1
                        }

                        /// Keyboard focus: a ring around the whole tile.
                        Rectangle {
                            anchors.fill: parent
                            anchors.margins: -2
                            radius: provider.tokens.radiusMedium + 2
                            color: "transparent"
                            border.color: provider.tokens.focus
                            border.width: tile.activeFocus ? 2 : 0
                        }

                        Keys.onReturnPressed: provider.activate(modelData)
                        Keys.onSpacePressed: provider.activate(modelData)
                        Keys.onMenuPressed: provider.togglePin(modelData)

                        MouseArea {
                            id: area
                            anchors.fill: parent
                            hoverEnabled: true
                            acceptedButtons: Qt.LeftButton | Qt.RightButton
                            onClicked: mouse => {
                                if (mouse.button === Qt.RightButton) {
                                    provider.togglePin(tile.modelData);
                                } else {
                                    provider.activate(tile.modelData);
                                }
                            }
                        }
                    }
                }

                Text {
                    visible: provider.notice.length > 0
                    color: provider.tokens.warning
                    font.pixelSize: provider.tokens.fontSmall
                    text: provider.notice
                }
            }
        }
    }
}
