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
///
/// That presentation is the light recipe's (`tokens.lightRecipe`). With any
/// other theme the Dock looks as it did before: 40 px lettered bubbles in a
/// pill 60 px thick. Only the input region (the visible pill, rounded) and
/// the accessible names are the same in both.
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

    /// The light recipe's presentation; false keeps the earlier one.
    readonly property bool soft: tokens !== null && tokens.lightRecipe === true
    readonly property bool motionEnabled: soft && tokens.motionEnabled && shown
    property real reveal: 1
    property NumberAnimation revealAnimation: NumberAnimation {
        target: provider; property: "reveal"; from: 0.98; to: 1
        duration: provider.tokens ? provider.tokens.motionPresent : 0
        easing.type: Easing.OutCubic
    }
    function settlePresentation() {
        revealAnimation.stop();
        reveal = 1;
    }
    // Focus confirmation belongs to the provider's observation lifetime, not
    // the array-model delegates (which rebuild on any window upsert).
    readonly property string focusedWindowId: {
        const window = client ? client.windows.find(item => item.focused === true) : null;
        return window ? window.id : "";
    }
    /// The windows list is a Core snapshot only while the client is online:
    /// before the first subscribe answer it is the empty placeholder, and
    /// after a disconnect it is stale. A client without `online` (fixtures)
    /// counts as always holding a snapshot.
    readonly property bool windowsSnapshot: !!client && client.online !== false
    property bool focusObserved: false
    property string observedFocusId: ""
    property string confirmationWindowId: ""
    property real focusScale: 1
    readonly property int confirmationIndex: entries.findIndex(entry =>
        entry.window && entry.window.id === confirmationWindowId)
    property NumberAnimation confirmationAnimation: NumberAnimation {
        target: provider; property: "focusScale"; from: 0.94; to: 1
        duration: provider.tokens ? provider.tokens.motionPresent : 0
        easing.type: Easing.OutBack
        easing.overshoot: 0
    }
    function settleConfirmation() {
        confirmationAnimation.stop();
        focusScale = 1;
        confirmationWindowId = "";
    }
    function observeFocus() {
        if (!ready || !windowsSnapshot) return;
        const next = focusedWindowId;
        if (!focusObserved) {
            focusObserved = true;
            observedFocusId = next;
            return; // The first snapshot is a baseline, not a focus transition.
        }
        if (next === observedFocusId) return;
        observedFocusId = next; // Observe even while hidden / motion disabled.
        settleConfirmation();
        if (next && shown && soft && tokens.motionEnabled) {
            confirmationWindowId = next;
            confirmationAnimation.start();
        }
    }
    onFocusedWindowIdChanged: observeFocus()
    // Going offline forgets the baseline, so the snapshot after a reconnect
    // establishes a new one instead of replaying what changed meanwhile.
    onWindowsSnapshotChanged: {
        if (!windowsSnapshot) {
            focusObserved = false;
            settleConfirmation();
        }
        observeFocus();
    }
    onMotionEnabledChanged: if (!motionEnabled) { settlePresentation(); settleConfirmation(); }
    onPositionChanged: { settlePresentation(); settleConfirmation(); }
    onScreenChanged: { settlePresentation(); settleConfirmation(); }
    readonly property int iconSize: 42
    readonly property int tileSize: soft ? 52 : 40
    readonly property int pillPadding: 8
    /// Space between the capsule and the screen edge.
    readonly property int edgeGap: 12
    readonly property int pillThickness: tileSize + pillPadding * 2
    readonly property int thickness: soft ? pillThickness + edgeGap + 4 : 60

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

    /// The indexed application for an id: the same id, or else (light
    /// recipe) the same last segment (a window's `foot` is the index's
    /// `org.codeberg.dnkl.foot`). The earlier Dock matched the id only.
    function appFor(appId) {
        const wanted = String(appId).toLowerCase();
        const tail = wanted.split(".").pop();
        return apps.find(item => String(item.app_id) === String(appId))
            || (soft ? apps.find(item => String(item.app_id).toLowerCase() === wanted)
                || apps.find(item => String(item.app_id).toLowerCase().split(".").pop() === tail) : null)
            || null;
    }

    function appName(appId) {
        const app = appFor(appId);
        return app ? app.name : appId;
    }

    /// The image for an application's icon, or "" when it has none the
    /// icon theme can resolve (the lettered tile is shown instead).
    function iconSource(appId) {
        if (!soft) {
            return "";
        }
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

    onShownChanged: {
        settlePresentation();
        if (!shown) settleConfirmation();
        if (shown) loadApps();
        // motionEnabled also depends on shown; its notification may follow
        // this handler. Read the new intent directly so show starts (and hide
        // never starts) the presentation, even on an immediate reverse.
        if (shown && soft && tokens.motionEnabled) revealAnimation.start();
    }
    Component.onCompleted: { ready = true; observeFocus(); }

    PanelWindow {
        id: dock

        readonly property bool vertical: provider.position === "left"
        /// The visible pill, which is also the input region.
        readonly property Item capsule: provider.soft ? pill : legacyPill

        visible: provider.shown
        anchors {
            bottom: provider.position === "bottom"
            left: provider.position === "left"
        }
        implicitWidth: provider.soft
            ? (vertical ? provider.thickness : pill.width + provider.edgeGap * 2)
            : (vertical ? provider.thickness : Math.max(160, strip.implicitWidth + provider.tokens.spaceSection * 2))
        implicitHeight: provider.soft
            ? (vertical ? pill.height + provider.edgeGap * 2 : provider.thickness)
            : (vertical ? Math.max(160, strip.implicitHeight + provider.tokens.spaceSection * 2) : provider.thickness)
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

        /// Input only on the visible pill, with its rounded ends (Quickshell
        /// 0.3.1 Region: `item` gives the rectangle, `radius` rounds it). The
        /// margin, the shadow and the corners outside the curve pass clicks on.
        mask: Region {
            item: dock.capsule
            radius: Math.round(dock.capsule.radius)
        }

        /// The earlier pill (themes other than the light recipe).
        Rectangle {
            id: legacyPill
            objectName: "dockLegacyPill"
            visible: !provider.soft
            anchors.fill: parent
            anchors.margins: provider.tokens.space
            radius: Math.min(width, height) / 2
            color: provider.tokens.surface
            border.color: provider.tokens.border
            border.width: 1
            opacity: provider.tokens.surfaceOpacity
        }

        Item {
            id: pill
            objectName: "dockCapsule"
            visible: provider.soft
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
                model: provider.shown && provider.soft && provider.tokens.shadowEnabled ? [0.30, 0.16, 0.07] : []

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
        }

        Grid {
            id: strip
            anchors.centerIn: provider.soft ? pill : parent
            flow: dock.vertical ? Grid.TopToBottom : Grid.LeftToRight
            rows: dock.vertical ? Math.max(1, provider.entries.length + 1) : 1
            columns: dock.vertical ? 1 : Math.max(1, provider.entries.length + 1)
            spacing: provider.tokens.space
            verticalItemAlignment: provider.soft ? Grid.AlignVCenter : Grid.AlignTop
            horizontalItemAlignment: provider.soft ? Grid.AlignHCenter : Grid.AlignLeft

            Repeater {
                model: provider.entries

                Item {
                    id: tile
                    required property var modelData
                    required property int index
                    readonly property bool running: !!modelData.window
                    readonly property bool current: running && modelData.window.focused === true
                    readonly property bool motionActive: provider.motionEnabled && visible
                    readonly property real feedbackTarget: !visible || !provider.shown ? 1
                        : area.pressed ? 0.90 : area.containsMouse || activeFocus ? 0.96 : 1
                    property real feedbackScale: 1
                    readonly property bool confirming: current && modelData.window.id === provider.confirmationWindowId
                        && index === provider.confirmationIndex
                    readonly property real confirmedScale: confirming ? provider.focusScale : 1
                    readonly property bool motionRunning: feedbackAnimation.running
                        || (confirming && provider.confirmationAnimation.running)
                    // Providers are standalone packages: use the same one-value
                    // stop/retarget policy locally, without importing Shell paths.
                    function retargetFeedback() {
                        feedbackAnimation.stop();
                        if (!motionActive || feedbackScale === feedbackTarget) {
                            feedbackScale = feedbackTarget;
                            return;
                        }
                        feedbackAnimation.from = feedbackScale;
                        feedbackAnimation.to = feedbackTarget;
                        feedbackAnimation.start();
                    }
                    function settleMotion() {
                        feedbackAnimation.stop();
                        feedbackScale = feedbackTarget;
                    }
                    onFeedbackTargetChanged: retargetFeedback()
                    onMotionActiveChanged: if (!motionActive) settleMotion()
                    NumberAnimation {
                        id: feedbackAnimation
                        target: tile; property: "feedbackScale"
                        duration: provider.tokens.motionFeedback
                        easing.type: Easing.OutCubic
                    }
                    Connections {
                        target: provider
                        function onPositionChanged() { tile.settleMotion(); }
                        function onScreenChanged() { tile.settleMotion(); }
                    }
                    objectName: "dockTile_" + modelData.appId
                    width: provider.tileSize
                    height: provider.tileSize
                    activeFocusOnTab: true
                    Accessible.role: Accessible.Button
                    Accessible.name: provider.accessibleName(modelData)
                    Accessible.onPressAction: provider.activate(modelData)

                    // ---- earlier presentation: a lettered bubble ----------
                    Rectangle {
                        objectName: "dockLegacyBubble"
                        visible: !provider.soft
                        anchors.fill: parent
                        radius: 20
                        color: tile.current ? provider.tokens.accent : provider.tokens.surfaceStrong
                        border.color: provider.tokens.border
                        border.width: 1

                        Text {
                            anchors.centerIn: parent
                            text: provider.appName(tile.modelData.appId).substring(0, 2)
                            color: tile.current ? provider.tokens.accentForeground : provider.tokens.foreground
                            font.pixelSize: provider.tokens.fontBody
                            font.bold: true
                        }
                    }

                    /// Running indicator: a dot, and the accessible name says it too.
                    Rectangle {
                        visible: !provider.soft && tile.running
                        width: 6
                        height: 6
                        radius: 3
                        color: provider.tokens.foreground
                        anchors.horizontalCenter: dock.vertical ? undefined : parent.horizontalCenter
                        anchors.verticalCenter: dock.vertical ? parent.verticalCenter : undefined
                        anchors.top: dock.vertical ? undefined : parent.bottom
                        anchors.left: dock.vertical ? parent.right : undefined
                        anchors.topMargin: 1
                        anchors.leftMargin: 1
                    }

                    Rectangle {
                        visible: !provider.soft
                        anchors.fill: parent
                        anchors.margins: -3
                        radius: width / 2
                        color: "transparent"
                        border.color: provider.tokens.focus
                        border.width: tile.activeFocus ? 2 : 0
                    }

                    // ---- light recipe: the application's icon -------------
                    /// Plate behind the window in use, and under the pointer.
                    Rectangle {
                        anchors.fill: parent
                        radius: provider.tokens.radiusMedium
                        visible: provider.soft && (tile.current || area.containsMouse)
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
                        scale: tile.feedbackScale * tile.confirmedScale * provider.reveal
                        visible: provider.soft && status === Image.Ready
                    }

                    /// Fallback: a lettered tile with the application's name.
                    Rectangle {
                        objectName: "dockIconFallback"
                        scale: tile.feedbackScale * tile.confirmedScale * provider.reveal
                        anchors.centerIn: parent
                        width: provider.iconSize
                        height: provider.iconSize
                        radius: provider.tokens.radiusMedium
                        visible: provider.soft && icon.status !== Image.Ready
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
                        visible: provider.soft && tile.running
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
                        visible: provider.soft
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
                        hoverEnabled: provider.soft
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
