import QtQuick
import Quickshell
import Quickshell.Wayland

/// Dock B (`ui.dock`): a pill on the left or bottom edge with pinned
/// applications and a running indicator. Its data is `desktop.launcher.list_apps`
/// plus `client.windows`; the pinned list lives in this entry's `config`
/// (`pinned`, `position`), so it survives a swap to another dock and back.
/// Pinning is a ChangeSet on that config, like any other write.
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

    readonly property int thickness: 60

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

    function appName(appId) {
        const app = apps.find(item => item.app_id === appId);
        return app ? app.name : appId;
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

        visible: provider.shown
        anchors {
            bottom: provider.position === "bottom"
            left: provider.position === "left"
        }
        implicitWidth: provider.position === "left" ? provider.thickness : Math.max(160, strip.implicitWidth + provider.tokens.spaceSection * 2)
        implicitHeight: provider.position === "left" ? Math.max(160, strip.implicitHeight + provider.tokens.spaceSection * 2) : provider.thickness
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

        Rectangle {
            anchors.fill: parent
            anchors.margins: provider.tokens.space
            radius: Math.min(width, height) / 2
            color: provider.tokens.surface
            border.color: provider.tokens.border
            border.width: 1
            opacity: provider.tokens.surfaceOpacity
        }

        Grid {
            id: strip
            anchors.centerIn: parent
            flow: provider.position === "left" ? Grid.TopToBottom : Grid.LeftToRight
            rows: provider.position === "left" ? Math.max(1, provider.entries.length + 1) : 1
            columns: provider.position === "left" ? 1 : Math.max(1, provider.entries.length + 1)
            spacing: provider.tokens.space

            Repeater {
                model: provider.entries

                Rectangle {
                    id: bubble
                    required property var modelData
                    width: 40
                    height: 40
                    radius: 20
                    color: modelData.window && modelData.window.focused ? provider.tokens.accent : provider.tokens.surfaceStrong
                    border.color: provider.tokens.border
                    border.width: 1
                    activeFocusOnTab: true
                    Accessible.role: Accessible.Button
                    Accessible.name: provider.appName(modelData.appId)
                        + (modelData.window ? provider.t(qsTr("（執行中）")) : "")
                        + (modelData.pinned ? provider.t(qsTr("（已釘選）")) : "")

                    Text {
                        anchors.centerIn: parent
                        text: provider.appName(bubble.modelData.appId).substring(0, 2)
                        color: bubble.modelData.window && bubble.modelData.window.focused ? provider.tokens.onAccent : provider.tokens.foreground
                        font.pixelSize: provider.tokens.fontBody
                        font.bold: true
                    }

                    /// Running indicator: a dot, and the accessible name says it too.
                    Rectangle {
                        visible: !!bubble.modelData.window
                        width: 6
                        height: 6
                        radius: 3
                        color: provider.tokens.foreground
                        anchors.horizontalCenter: provider.position === "bottom" ? parent.horizontalCenter : undefined
                        anchors.verticalCenter: provider.position === "left" ? parent.verticalCenter : undefined
                        anchors.top: provider.position === "bottom" ? parent.bottom : undefined
                        anchors.left: provider.position === "left" ? parent.right : undefined
                        anchors.topMargin: 1
                        anchors.leftMargin: 1
                    }

                    Rectangle {
                        anchors.fill: parent
                        anchors.margins: -3
                        radius: width / 2
                        color: "transparent"
                        border.color: provider.tokens.focus
                        border.width: parent.activeFocus ? 2 : 0
                    }

                    Keys.onReturnPressed: provider.activate(modelData)
                    Keys.onSpacePressed: provider.activate(modelData)
                    Keys.onMenuPressed: provider.togglePin(modelData)

                    MouseArea {
                        anchors.fill: parent
                        acceptedButtons: Qt.LeftButton | Qt.RightButton
                        onClicked: mouse => {
                            if (mouse.button === Qt.RightButton) {
                                provider.togglePin(bubble.modelData);
                            } else {
                                provider.activate(bubble.modelData);
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
