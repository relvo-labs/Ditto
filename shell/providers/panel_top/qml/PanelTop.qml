pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Services.Pipewire
import Quickshell.Networking

/// `ui.panel_top` provider: workspaces, the focused window, volume, network,
/// clock, the entrances to the four centers and the power menu. Nothing here
/// polls; desktop values arrive with a snapshot or an event. Volume and
/// network are UI reads of the system (PipeWire, NetworkManager/networkd) and are not
/// Ditto configuration.
///
/// Provider interface (plan/03/04 §2.1): the host sets client, tokens, config,
/// screen, slotName and shown; the provider declares reservedEdge, ready,
/// healthy() and release(). It reaches Core only through `client`.
///
/// Optionally a panel offers `statusRegion`, an Item in its bar where the
/// Shell places the mounted `ui.status_item` members (shell/core/StatusArea.qml).
/// The panel lays the region out and nothing more: which items are in it,
/// and in what order, is the Shell's. A panel without one still works; the
/// Shell then shows the items in a strip of its own.
Scope {
    id: provider

    property var client: null
    property var tokens: null
    property var config: ({})
    property var screen: null
    property string slotName: ""
    property string entryId: ""
    property bool shown: false

    readonly property string reservedEdge: "top"
    readonly property bool soft: tokens && tokens.lightRecipe === true
    readonly property Item statusRegion: statusRow
    property bool ready: false
    property bool menuOpen: false
    /// The Ditto language ("zh-TW" or "en"), from the Shell's translator.
    readonly property string language: client && client.tr && client.tr.language === "en" ? "en" : "zh-TW"
    /// The control whose tooltip is wanted (hover or keyboard focus).
    property FeedbackButton tooltipOwner: null
    property bool tooltipShown: false

    readonly property var networkDevices: Networking.devices ? Networking.devices.values : []
    readonly property bool nmConnected: networkDevices.some(device => device.connected)
    readonly property bool networkdConnected: networkdSource.status === Loader.Ready
        && networkdSource.item !== null && networkdSource.item.connected
    readonly property bool networkConnected: nmConnected || networkdConnected
    readonly property string networkLabel: networkdConnected
        ? provider.t(qsTr("網路已連線（網際網路狀態未知）"))
        : Networking.backend === NetworkBackendType.None ? provider.t(qsTr("網路不可用"))
        : !nmConnected && Networking.connectivity === NetworkConnectivity.Unknown ? provider.t(qsTr("網路狀態未知"))
        : nmConnected ? provider.t(qsTr("網路已連線")) : provider.t(qsTr("網路未連線"))

    // Optional, same-process Qt/D-Bus observer. NM remains the source for its
    // connected devices, including limited/portal/unknown connectivity. No
    // networkd observation or retained snapshot while hidden or NM is connected.
    Loader {
        id: networkdSource
        objectName: "panelNetworkdSource"
        active: provider.shown && !provider.nmConnected
        visible: false
        source: "network/NetworkdSource.qml"
    }

    function wantTooltip(owner, wanted) {
        if (wanted) {
            tooltipOwner = owner;
            tooltipShown = false;
            tooltipDelay.restart();
        } else if (tooltipOwner === owner) {
            tooltipDelay.stop();
            tooltipShown = false;
            tooltipOwner = null;
        }
    }

    function healthy() {
        return ready && client !== null && tokens !== null;
    }

    function release() {
        menuOpen = false;
        shown = false;
        tooltipDelay.stop();
        tooltipShown = false;
        tooltipOwner = null;
    }

    function t(source) {
        return client ? client.t(source) : source;
    }

    function invoke(commandId) {
        menuOpen = false;
        client.capability("desktop.commands.invoke", { command_id: commandId, args: {} }, null, function (error) {
            console.log("ditto-panel command refused: " + error.name + " " + error.message);
        });
    }

    function session(action) {
        menuOpen = false;
        client.capability("desktop.session." + action, {}, null, function (error) {
            console.log("ditto-panel session " + action + " refused: " + error.name + " " + error.message);
        });
    }

    Component.onCompleted: ready = true

    PwObjectTracker {
        objects: provider.shown && Pipewire.defaultAudioSink ? [Pipewire.defaultAudioSink] : []
    }

    SystemClock {
        id: clock
        enabled: provider.shown
        precision: SystemClock.Minutes
    }

    Timer {
        id: tooltipDelay
        interval: 600
        onTriggered: provider.tooltipShown = provider.tooltipOwner !== null
    }

    PanelWindow {
        id: panel

        visible: provider.shown
        anchors { top: true; left: true; right: true }
        implicitHeight: provider.soft ? lightPanel.height : 34
        exclusiveZone: provider.shown ? implicitHeight : 0
        color: "transparent"
        // Mapped without keyboard interactivity, then on demand: a surface
        // that maps on demand is given the keyboard focus by the compositor,
        // so swapping a Dock would take focus from the window in use.
        property bool mapped: false
        onVisibleChanged: if (!visible) mapped = false
        Timer {
            interval: 250
            running: panel.visible && !panel.mapped
            onTriggered: panel.mapped = true
        }
        WlrLayershell.keyboardFocus: mapped ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None
        WlrLayershell.namespace: "ditto-panel-top"

        mask: provider.soft ? lightRegion : null
        Region {
            id: lightRegion
            Region { intersection: Intersection.Combine; item: provider.soft ? leftCapsule : null; radius: leftCapsule.radius }
            Region { intersection: Intersection.Combine; item: provider.soft ? workspaceCapsule : null; radius: workspaceCapsule.radius }
            Region { intersection: Intersection.Combine; item: provider.soft ? statusCapsule : null; radius: statusCapsule.radius }
        }

        Item {
            anchors.fill: parent
            visible: !provider.soft
        Rectangle {
            anchors.fill: parent
            anchors.margins: 2
            radius: provider.tokens.radiusSmall
            color: provider.tokens.surface
            border.color: provider.tokens.border
            border.width: 1
            opacity: provider.tokens.surfaceOpacity
        }

        Row {
            anchors.left: parent.left
            anchors.leftMargin: provider.tokens.spaceWide
            anchors.verticalCenter: parent.verticalCenter
            spacing: provider.tokens.space

            Rectangle {
                width: brand.implicitWidth + provider.tokens.spaceWide
                height: 22
                radius: provider.tokens.radiusSmall
                color: menuArea.containsMouse || activeFocus ? provider.tokens.surfaceStrong : "transparent"
                activeFocusOnTab: true
                Accessible.role: Accessible.Button
                Accessible.name: provider.t(qsTr("Ditto 選單"))
                Keys.onReturnPressed: provider.menuOpen = !provider.menuOpen
                Keys.onSpacePressed: provider.menuOpen = !provider.menuOpen

                Text {
                    id: brand
                    anchors.centerIn: parent
                    text: "Ditto ▾"
                    color: provider.tokens.foreground
                    font.pixelSize: provider.tokens.fontSmall
                    font.bold: true
                }

                Rectangle {
                    anchors.fill: parent
                    anchors.margins: -2
                    radius: parent.radius + 2
                    color: "transparent"
                    border.color: provider.tokens.focus
                    border.width: parent.activeFocus ? 2 : 0
                }

                MouseArea {
                    id: menuArea
                    anchors.fill: parent
                    hoverEnabled: true
                    onClicked: provider.menuOpen = !provider.menuOpen
                }
            }

            Repeater {
                model: provider.client ? provider.client.workspaces : []

                Rectangle {
                    required property var modelData
                    width: label.implicitWidth + provider.tokens.spaceWide
                    height: 22
                    radius: provider.tokens.radiusSmall
                    color: modelData.active ? provider.tokens.accent : "transparent"
                    border.color: provider.tokens.border
                    border.width: modelData.active ? 0 : 1
                    activeFocusOnTab: true
                    Accessible.role: Accessible.Button
                    Accessible.name: provider.t(qsTr("工作區 %1")).arg(modelData.name)
                        + (modelData.active ? provider.t(qsTr("（目前）")) : "")

                    Text {
                        id: label
                        anchors.centerIn: parent
                        text: modelData.name
                        color: modelData.active ? provider.tokens.accentForeground : provider.tokens.foreground
                        font.pixelSize: provider.tokens.fontSmall
                    }

                    // Focus is visible on its own, not only by colour.
                    Rectangle {
                        anchors.fill: parent
                        anchors.margins: -2
                        radius: parent.radius + 2
                        color: "transparent"
                        border.color: provider.tokens.focus
                        border.width: parent.activeFocus ? 2 : 0
                    }

                    Keys.onReturnPressed: provider.client.activateWorkspace(modelData.id)
                    Keys.onSpacePressed: provider.client.activateWorkspace(modelData.id)

                    MouseArea {
                        anchors.fill: parent
                        enabled: provider.client.capabilityAvailable("desktop.workspaces.activate")
                        onClicked: provider.client.activateWorkspace(modelData.id)
                    }
                }
            }
        }

        Text {
            anchors.centerIn: parent
            width: parent.width * 0.34
            elide: Text.ElideRight
            horizontalAlignment: Text.AlignHCenter
            color: provider.tokens.foreground
            font.pixelSize: provider.tokens.fontBody
            text: {
                const focused = provider.client ? provider.client.windows.find(item => item.focused) : null;
                return focused ? focused.title : provider.t(qsTr("沒有作用中的視窗"));
            }
        }

        Row {
            anchors.right: parent.right
            anchors.rightMargin: provider.tokens.spaceWide
            anchors.verticalCenter: parent.verticalCenter
            spacing: provider.tokens.spaceWide

            Text {
                color: provider.client && provider.client.online ? provider.tokens.foregroundMuted : provider.tokens.warning
                font.pixelSize: provider.tokens.fontSmall
                text: provider.client && provider.client.online
                    ? provider.t(qsTr("%1 個視窗")).arg(provider.client.windows.length)
                    : (provider.client ? provider.client.status : "")
            }

            /// Volume: shown and nudged here; details open pavucontrol.
            Text {
                id: volume
                readonly property var sink: Pipewire.defaultAudioSink
                readonly property bool known: sink !== null && sink.audio !== null && Pipewire.ready
                color: provider.tokens.foregroundMuted
                font.pixelSize: provider.tokens.fontSmall
                text: !known ? provider.t(qsTr("音量不可用"))
                    : sink.audio.muted ? provider.t(qsTr("音量 靜音"))
                    : provider.t(qsTr("音量 %1%")).arg(Math.round(sink.audio.volume * 100))
                Accessible.role: Accessible.Button
                Accessible.name: text

                MouseArea {
                    anchors.fill: parent
                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                    onClicked: mouse => {
                        if (mouse.button === Qt.RightButton) {
                            provider.client.launchApp("pavucontrol");
                        } else if (volume.known) {
                            volume.sink.audio.muted = !volume.sink.audio.muted;
                        }
                    }
                    onWheel: wheel => {
                        if (volume.known) {
                            const step = wheel.angleDelta.y > 0 ? 0.05 : -0.05;
                            volume.sink.audio.volume = Math.max(0, Math.min(1.5, volume.sink.audio.volume + step));
                        }
                    }
                }
            }

            /// Read-only link state. a routable networkd link does not prove Internet reachability.
            Text {
                id: network
                objectName: "panelNetworkLegacy"
                readonly property bool connected: provider.networkConnected
                color: connected ? provider.tokens.foregroundMuted : provider.tokens.warning
                font.pixelSize: provider.tokens.fontSmall
                text: provider.networkdConnected ? provider.networkLabel
                    : connected ? provider.t(qsTr("網路已連線")) : provider.t(qsTr("網路未連線"))
                Accessible.role: Accessible.Button
                Accessible.name: text

                MouseArea {
                    anchors.fill: parent
                    onClicked: provider.client.launchApp("nm-connection-editor")
                }
            }

            /// Status items (`ui.status_item`), placed here by the Shell.
            Item {
                id: legacyStatusHost
                width: statusRow.implicitWidth
                height: statusRow.implicitHeight
            }

            Text {
                color: provider.tokens.foreground
                font.pixelSize: provider.tokens.fontSmall
                text: Qt.formatDateTime(clock.date, "HH:mm")
            }
        }
        } // Original presentation, retained for every other recipe.

        Item {
            id: lightPanel
            anchors.left: parent.left
            anchors.right: parent.right
            height: Math.max(leftCapsule.height, workspaceCapsule.height, statusCapsule.height) + 8
            visible: provider.soft
            readonly property real capsuleHeight: Math.max(28, provider.tokens.fontSmall + 12)
            // All measurements are intrinsic; allocations never depend on the
            // wrapped positioners, so resize/member updates cannot bind in a loop.
            readonly property real edge: 18
            readonly property real gap: 12
            readonly property real usableWidth: Math.max(0, width - edge * 2 - gap * 2)
            FontMetrics { id: workspaceMetrics; font.pixelSize: provider.tokens.fontSmall }
            readonly property real workspaceCell: Math.max(31, ...(provider.client ? provider.client.workspaces : [])
                .map(workspace => workspaceMetrics.advanceWidth(workspace.name) + 16))
            readonly property int workspaceCount: provider.client ? provider.client.workspaces.length : 0
            // Widths of the status grid's laid-out members, in order. The
            // status-item host takes part only while it holds members, like
            // the Grid (an empty host would otherwise leave a spacing gap).
            readonly property var statusMembers: [lightNetwork.width, lightVolume.width]
                .concat(lightStatusHost.visible ? [statusRow.implicitWidth] : [])
                .concat([lightClock.implicitWidth])
            readonly property real leftMinimum: lightMenu.width + 12
            function workspaceExtent(rows) {
                const columns = Math.ceil(Math.max(1, workspaceCount) / rows);
                return columns * workspaceCell + (columns - 1) * 4 + 8;
            }
            function statusExtent(columns) {
                const used = Math.min(columns, statusMembers.length);
                let total = 0;
                for (let column = 0; column < used; ++column) {
                    let widest = 0;
                    for (let index = column; index < statusMembers.length; index += used)
                        widest = Math.max(widest, statusMembers[index]);
                    total += widest;
                }
                return total + Math.max(0, used - 1) * 12 + 16;
            }
            // Narrow screens (#105 C1): the fewest rows that fit beside the
            // shortest left capsule. At equal height the status capsule keeps
            // more columns and the workspaces fewer rows, so the workspaces
            // wrap first, then the status capsule takes two columns, one last.
            readonly property var arrangement: {
                const room = usableWidth - leftMinimum;
                const rowsMax = Math.max(1, workspaceCount);
                let best = null;
                for (let rows = 1; rows <= rowsMax; ++rows) {
                    for (const columns of [4, 2, 1]) {
                        const workspaces = workspaceExtent(rows), status = statusExtent(columns);
                        if (workspaces + status > room) continue;
                        const height = Math.max(rows, Math.ceil(statusMembers.length / Math.min(columns, statusMembers.length)));
                        const key = [height, -columns, rows];
                        if (best === null || key[0] < best.key[0] || (key[0] === best.key[0]
                                && (key[1] < best.key[1] || (key[1] === best.key[1] && key[2] < best.key[2]))))
                            best = { key: key, rows: rows, columns: columns, workspaces: workspaces, status: status };
                    }
                }
                return best !== null ? best
                    : { rows: rowsMax, columns: 1, workspaces: workspaceExtent(rowsMax), status: statusExtent(1) };
            }
            // A single-row status capsule keeps the 242 px reference width when
            // there is room; a wrapped one is exactly as wide as its content.
            readonly property real statusPreferred: arrangement.columns === 4 ? Math.max(242, arrangement.status) : arrangement.status
            readonly property real workspaceWidth: arrangement.workspaces
            readonly property real leftWidth: Math.min(360, Math.max(leftMinimum, usableWidth - workspaceWidth - statusPreferred))
            readonly property real statusWidth: Math.max(arrangement.status, Math.min(statusPreferred, usableWidth - leftWidth - workspaceWidth))
            readonly property int workspaceColumns: Math.ceil(Math.max(1, workspaceCount) / arrangement.rows)
            // Never more grid columns than members: an empty column still
            // gets spacing and would push the content off centre (#105 C3).
            readonly property int statusColumns: Math.max(1, Math.min(arrangement.columns, statusMembers.length))

            SoftCapsule {
                id: leftCapsule
                objectName: "panelLeft"
                x: 18; y: 4
                width: lightPanel.leftWidth
                height: lightPanel.capsuleHeight
                Row {
                    anchors.fill: parent
                    anchors.leftMargin: 4; anchors.rightMargin: 8
                    spacing: 8
                    FeedbackButton {
                        id: lightMenu
                        objectName: "panelMenu"
                        width: lightBrand.implicitWidth + 12
                        height: leftCapsule.height
                        accessibleLabel: provider.t(qsTr("Ditto 選單"))
                        tooltipText: lightTitle.text + " · " + windowCount.text
                        onActivated: provider.menuOpen = !provider.menuOpen
                        Text {
                            id: lightBrand
                            anchors.centerIn: parent
                            text: "Ditto ▾"
                            color: provider.tokens.foreground
                            font.pixelSize: provider.tokens.fontSmall
                            font.bold: true
                        }
                    }
                    Text {
                        id: lightTitle
                        objectName: "panelTitle"
                        width: Math.max(0, parent.width - lightMenu.width - (windowCount.visible ? windowCount.width + 8 : 0) - 8)
                        visible: width > 0
                        height: parent.height
                        verticalAlignment: Text.AlignVCenter
                        elide: Text.ElideRight
                        color: provider.tokens.foreground
                        font.pixelSize: provider.tokens.fontSmall
                        text: {
                            const focused = provider.client ? provider.client.windows.find(item => item.focused) : null;
                            return focused ? focused.title : provider.t(qsTr("沒有作用中的視窗"));
                        }
                        Accessible.role: Accessible.StaticText
                        Accessible.name: text
                    }
                    Text {
                        id: windowCount
                        visible: leftCapsule.width >= lightMenu.width + implicitWidth + 28
                        height: parent.height
                        verticalAlignment: Text.AlignVCenter
                        font.pixelSize: provider.tokens.fontSmall
                        color: provider.client && provider.client.online ? provider.tokens.foregroundMuted : provider.tokens.warning
                        text: provider.client && provider.client.online
                            ? provider.t(qsTr("%1 個視窗")).arg(provider.client.windows.length)
                            : (provider.client ? provider.client.status : "")
                    }
                }
            }

            SoftCapsule {
                id: workspaceCapsule
                objectName: "panelWorkspaces"
                x: Math.max(leftCapsule.x + leftCapsule.width + lightPanel.gap,
                    Math.min((lightPanel.width - width) / 2, statusCapsule.x - lightPanel.gap - width))
                y: 4
                width: lightPanel.workspaceWidth
                height: Math.max(lightPanel.capsuleHeight, workspaceStrip.implicitHeight + 6)
                Grid {
                    id: workspaceStrip
                    objectName: "panelWorkspaceStrip"
                    anchors.centerIn: parent
                    columns: lightPanel.workspaceColumns
                    spacing: 4
                    Repeater {
                        model: provider.client ? provider.client.workspaces : []
                        FeedbackButton {
                            id: workspaceButton
                            required property var modelData
                            objectName: "panelWorkspace_" + modelData.id
                            width: lightPanel.workspaceCell
                            height: lightPanel.capsuleHeight - 6
                            interactive: provider.client && provider.client.capabilityAvailable("desktop.workspaces.activate")
                            accessibleLabel: provider.t(qsTr("工作區 %1")).arg(modelData.name)
                                + (modelData.active ? provider.t(qsTr("（目前）")) : "")
                            onActivated: if (interactive) provider.client.activateWorkspace(modelData.id)
                            Rectangle {
                                anchors.fill: parent
                                radius: height / 2
                                color: workspaceButton.modelData.active ? provider.tokens.accent : "transparent"
                            }
                            Text {
                                id: workspaceText
                                anchors.centerIn: parent
                                text: workspaceButton.modelData.name
                                color: workspaceButton.modelData.active ? provider.tokens.accentForeground : provider.tokens.foreground
                                font.pixelSize: provider.tokens.fontSmall
                            }
                        }
                    }
                }
            }

            SoftCapsule {
                id: statusCapsule
                objectName: "panelStatus"
                x: lightPanel.width - width - 18; y: 4
                width: lightPanel.statusWidth
                height: Math.max(lightPanel.capsuleHeight, statusStrip.implicitHeight + 4)
                Grid {
                    id: statusStrip
                    objectName: "panelStatusStrip"
                    anchors.centerIn: parent
                    columns: lightPanel.statusColumns
                    columnSpacing: 12
                    rowSpacing: 4
                    verticalItemAlignment: Grid.AlignVCenter
                    StatusButton {
                        id: lightNetwork
                        objectName: "panelNetwork"
                        height: lightPanel.capsuleHeight - 4
                        readonly property bool available: provider.networkdConnected || Networking.backend !== NetworkBackendType.None
                        readonly property var devices: provider.networkDevices
                        readonly property bool connected: provider.networkConnected
                        readonly property bool unknown: available && !connected && Networking.connectivity === NetworkConnectivity.Unknown
                        // The device the icon describes: a connected one (wired
                        // first), else a Wi-Fi adapter, else a wired one.
                        readonly property var device: {
                            const live = devices.filter(item => item.connected);
                            return live.find(item => item.type === DeviceType.Wired) || live.find(item => item.type === DeviceType.Wifi)
                                || live[0] || devices.find(item => item.type === DeviceType.Wifi)
                                || devices.find(item => item.type === DeviceType.Wired) || null;
                        }
                        readonly property string kind: provider.networkdConnected ? networkdSource.item.kind
                            : device && device.type === DeviceType.Wired ? "wired"
                            : device && device.type === DeviceType.Wifi ? "wireless" : "other"
                        accessibleLabel: provider.networkLabel
                        // Connected, disconnected, unknown per device type (#102 B2).
                        iconName: !available ? "network-error-symbolic" : ({
                            wired: ["network-wired-symbolic", "network-wired-disconnected-symbolic", "network-wired-acquiring-symbolic"],
                            wireless: ["network-wireless-signal-excellent-symbolic", "network-wireless-offline-symbolic", "network-wireless-acquiring-symbolic"],
                            other: ["network-transmit-receive-symbolic", "network-offline-symbolic", "network-idle-symbolic"]
                        })[kind][connected ? 0 : unknown ? 2 : 1]
                        // A mark still distinguishes unknown/unavailable if a theme aliases icons.
                        marker: !available ? "!" : unknown || provider.networkdConnected ? "?" : ""
                        onActivated: if (provider.client) provider.client.launchApp("nm-connection-editor")
                    }
                    StatusButton {
                        id: lightVolume
                        objectName: "panelVolume"
                        height: lightPanel.capsuleHeight - 4
                        readonly property var sink: Pipewire.defaultAudioSink
                        readonly property bool known: Pipewire.ready && sink !== null && sink.audio !== null
                        accessibleLabel: !known ? provider.t(qsTr("音量不可用"))
                            : sink.audio.muted ? provider.t(qsTr("音量 靜音"))
                            : provider.t(qsTr("音量 %1%")).arg(Math.round(sink.audio.volume * 100))
                        iconName: !known ? "audio-card-symbolic" : sink.audio.muted ? "audio-volume-muted-symbolic"
                            : sink.audio.volume < 1 / 3 ? "audio-volume-low-symbolic"
                            : sink.audio.volume < 2 / 3 ? "audio-volume-medium-symbolic" : "audio-volume-high-symbolic"
                        marker: !known ? "!" : sink.audio.muted ? "∕" : ""
                        // Space and the toggle action mute; Enter, the press
                        // action and right click open details (#102 B1).
                        spaceToggles: known
                        Accessible.checkable: known
                        Accessible.checked: known && sink.audio.muted
                        Accessible.onToggleAction: if (known) toggled()
                        onToggled: if (known) sink.audio.muted = !sink.audio.muted
                        onActivated: button => {
                            // Left click toggles mute; other paths open details.
                            if (button === Qt.LeftButton) toggled();
                            else if (provider.client) provider.client.launchApp("pavucontrol");
                        }
                        onScrolled: delta => {
                            if (known) sink.audio.volume = Math.max(0, Math.min(1.5, sink.audio.volume + (delta > 0 ? 0.05 : -0.05)));
                        }
                    }
                    Item {
                        id: lightStatusHost
                        // Out of the grid while empty: no gap, content stays centred.
                        visible: statusRow.children.length > 0
                        width: statusRow.implicitWidth
                        height: statusRow.implicitHeight
                    }
                    Text {
                        id: lightClock
                        objectName: "panelClock"
                        height: lightPanel.capsuleHeight - 4
                        verticalAlignment: Text.AlignVCenter
                        color: provider.tokens.foreground
                        font.pixelSize: provider.tokens.fontSmall
                        // Ditto language with the weekday (#102 B3); 24-hour, no seconds.
                        //: Top bar clock: a Qt date pattern (ddd is the short weekday name).
                        text: clock.date.toLocaleString(Qt.locale(provider.language === "en" ? "en_US" : "zh_TW"),
                                                        provider.t(qsTr("M月d日 ddd HH:mm")))
                        Accessible.role: Accessible.StaticText
                        Accessible.name: text
                    }
                }
            }
        }
    }

    // StatusArea retains this exact Item between appearance transactions.
    // Move its layout host, never the members or the public region identity.
    Row {
        id: statusRow
        objectName: "panelStatusItems"
        parent: provider.soft ? lightStatusHost : legacyStatusHost
        spacing: provider.tokens.spaceWide
        Accessible.role: Accessible.StatusBar
        Accessible.name: provider.t(qsTr("狀態列項目"))
    }

    component SoftCapsule: Rectangle {
        radius: Math.floor(Math.min(width, height, lightPanel.capsuleHeight) / 2)
        // Only the fill's alpha changes, so text/focus remain fully opaque.
        color: Qt.rgba(provider.tokens.surface.r, provider.tokens.surface.g, provider.tokens.surface.b,
                       provider.tokens.reducedTransparency ? 1 : provider.tokens.surface.a * provider.tokens.surfaceOpacity)
        border.color: provider.tokens.reducedTransparency ? provider.tokens.border : provider.tokens.highlight
        border.width: 1
    }

    component FeedbackButton: Item {
        id: button
        property string accessibleLabel: ""
        property bool interactive: true
        property string tooltipText: ""
        /// Space emits toggled() instead of activated() (volume: mute).
        property bool spaceToggles: false
        enabled: interactive
        property int pointerButtons: Qt.LeftButton
        readonly property real feedbackTarget: !interactive || !visible || !provider.shown ? 1
            : area.pressed ? 0.90 : area.containsMouse || activeFocus ? 0.96 : 1
        property real feedbackScale: 1
        readonly property bool motionRunning: feedback.running
        readonly property bool motionActive: interactive && visible && provider.shown && provider.tokens.motionEnabled
        default property alias content: visual.data
        signal activated(int button)
        signal toggled()
        signal scrolled(real delta)
        activeFocusOnTab: true
        Accessible.role: Accessible.Button
        Accessible.name: accessibleLabel
        Accessible.description: tooltipText
        // The tooltip is the provider's own popup surface (#105 C2).
        readonly property bool wantsTooltip: provider.shown && visible && tooltipText !== "" && interactive
            && (area.containsMouse || activeFocus)
        onWantsTooltipChanged: provider.wantTooltip(button, wantsTooltip)
        Component.onDestruction: provider.wantTooltip(button, false)
        Accessible.onPressAction: if (interactive) activated(Qt.NoButton)
        Keys.onReturnPressed: if (interactive) activated(Qt.NoButton)
        Keys.onEnterPressed: if (interactive) activated(Qt.NoButton)
        Keys.onSpacePressed: if (interactive) { if (spaceToggles) toggled(); else activated(Qt.NoButton); }
        function retarget() {
            feedback.stop();
            if (!motionActive) { feedbackScale = feedbackTarget; return; }
            feedback.from = feedbackScale; feedback.to = feedbackTarget; feedback.start();
        }
        onFeedbackTargetChanged: retarget()
        onMotionActiveChanged: if (!motionActive) { feedback.stop(); feedbackScale = feedbackTarget; }
        data: [
            Item {
                id: visual
                anchors.fill: parent
                scale: button.feedbackScale
            },
            NumberAnimation {
                id: feedback
                target: button; property: "feedbackScale"
                duration: 120
                easing.type: Easing.OutCubic
            },
            Rectangle {
                objectName: button.objectName + "_focus"
                anchors.fill: parent
                radius: height / 2
                color: "transparent"
                border.color: provider.tokens.focus
                border.width: 2
                visible: button.activeFocus
            },
            MouseArea {
                id: area
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: button.pointerButtons
                onClicked: mouse => { if (button.interactive) button.activated(mouse.button); }
                onWheel: wheel => { if (button.interactive) button.scrolled(wheel.angleDelta.y); }
            }
        ]
    }

    component StatusButton: FeedbackButton {
        id: statusButton
        pointerButtons: Qt.LeftButton | Qt.RightButton
        property string iconName: ""
        property string marker: ""
        tooltipText: accessibleLabel
        Accessible.description: ""
        width: statusIcon.status === Image.Ready ? 28 : fallback.implicitWidth + 8
        SymbolicIcon {
            id: statusIcon
            objectName: statusButton.objectName + "Icon"
            anchors.centerIn: parent
            width: 18; height: 18
            color: provider.tokens.foreground
            source: Quickshell.iconPath(statusButton.iconName, true)
            visible: status !== Image.Null && status !== Image.Error
        }
        Text {
            objectName: statusButton.objectName + "Marker"
            // One pixel further out and a knock-out ring in the capsule's own
            // colour, so the mark never reads as part of the glyph (#105 C3).
            anchors.right: parent.right; anchors.top: parent.top; anchors.rightMargin: -1
            visible: statusIcon.status === Image.Ready && statusButton.marker !== ""
            text: statusButton.marker
            color: provider.tokens.foreground
            style: Text.Outline
            styleColor: Qt.rgba(provider.tokens.surface.r, provider.tokens.surface.g, provider.tokens.surface.b, 1)
            font.pixelSize: provider.tokens.fontSmall
            font.bold: true
        }
        Text {
            id: fallback
            objectName: statusButton.objectName + "Fallback"
            anchors.centerIn: parent
            visible: statusIcon.status !== Image.Ready
            text: statusButton.accessibleLabel
            color: provider.tokens.foregroundMuted
            font.pixelSize: provider.tokens.fontSmall
        }
    }

    // Paint only when source/colour/size/device ratio changes (18×18 at the
    // default recipe). This CPU alpha mask also works without shaders. The
    // SVG is rasterised at the device size and recoloured pixel for pixel in
    // device pixels, so a 2× output stays as sharp as the theme draws it
    // (#105 C3). Symbolic SVGs encode levels in their alpha, so retain it
    // (including antialiasing) — except for a glyph with no opaque part at
    // all (a whole icon drawn dimmed, e.g. Yaru's offline Wi-Fi at 50 %):
    // that one is raised to full strength so its thin lines stay legible
    // (#105 O1). Neutral shapes use foreground; red error accents use the
    // semantic danger colour instead of losing their secondary colour cue.
    component SymbolicIcon: Item {
        id: glyph
        property alias source: sourceImage.source
        property color color: provider.tokens.foreground
        property color errorColor: provider.tokens.danger
        readonly property int status: sourceImage.status !== Image.Ready ? sourceImage.status
            : paint.loaded && painted ? Image.Ready : Image.Loading
        property bool painted: false
        readonly property real ratio: Screen.devicePixelRatio > 0 ? Screen.devicePixelRatio : 1
        readonly property int deviceWidth: Math.max(1, Math.round(width * ratio))
        readonly property int deviceHeight: Math.max(1, Math.round(height * ratio))
        /// The source's highest alpha (0–1) and whether it was raised.
        property real peakAlpha: 0
        property bool normalized: false
        function loadSource() {
            painted = false;
            paint.loaded = false;
            if (paint.requested !== "") paint.unloadImage(paint.requested);
            paint.requested = String(source);
            if (paint.requested !== "") {
                paint.loadImage(source, Qt.size(deviceWidth, deviceHeight));
                // Cached Canvas images may already be ready without emitting
                // another imageLoaded signal for this URL.
                paint.loaded = paint.isImageLoaded(source);
                paint.requestPaint();
            }
        }
        onSourceChanged: loadSource()
        onDeviceWidthChanged: loadSource()
        onDeviceHeightChanged: loadSource()
        Component.onCompleted: loadSource()
        onColorChanged: paint.requestPaint()
        onErrorColorChanged: paint.requestPaint()
        Image { id: sourceImage; visible: false; sourceSize.width: glyph.width; sourceSize.height: glyph.height }
        Canvas {
            id: paint
            anchors.fill: parent
            property bool loaded: false
            property string requested: ""
            onImageLoaded: { loaded = isImageLoaded(glyph.source); requestPaint(); }
            onPaint: {
                if (!loaded || width <= 0 || height <= 0) return;
                const w = glyph.deviceWidth, h = glyph.deviceHeight;
                const ctx = getContext("2d");
                ctx.clearRect(0, 0, width, height);
                ctx.save();
                ctx.scale(1 / glyph.ratio, 1 / glyph.ratio); // device pixels from here
                ctx.drawImage(glyph.source, 0, 0, w, h);
                const pixels = ctx.getImageData(0, 0, w, h);
                ctx.clearRect(0, 0, w, h);
                let peak = 0;
                for (let offset = 3; offset < pixels.data.length; offset += 4) peak = Math.max(peak, pixels.data[offset]);
                const gain = peak > 0 && peak < 192 ? 255 / peak : 1;
                for (let y = 0; y < h; ++y) {
                    for (let x = 0; x < w; ++x) {
                        const offset = (y * w + x) * 4;
                        const alpha = pixels.data[offset + 3];
                        if (alpha === 0) continue;
                        const red = pixels.data[offset];
                        const isError = red > pixels.data[offset + 1] * 1.5 && red > pixels.data[offset + 2] * 1.25;
                        ctx.fillStyle = isError ? glyph.errorColor : glyph.color;
                        ctx.globalAlpha = Math.min(1, alpha * gain / 255);
                        ctx.fillRect(x, y, 1, 1);
                    }
                }
                ctx.restore();
                ctx.globalAlpha = 1;
                glyph.peakAlpha = peak / 255;
                glyph.normalized = gain !== 1;
                glyph.painted = true;
            }
        }
    }

    /// The Ditto menu: the four centers, the launcher and the session.
    PopupWindow {
        id: menu
        visible: provider.shown && provider.menuOpen
        anchor.window: panel
        anchor.rect.x: provider.soft ? leftCapsule.x : 8
        // Light: just below the Ditto capsule, even when wrapped pills make
        // the bar taller (#105 C1); legacy: below the bar.
        anchor.rect.y: provider.soft ? leftCapsule.y + leftCapsule.height + 4 : panel.height
        implicitWidth: 220
        implicitHeight: menuColumn.implicitHeight + provider.tokens.space * 2
        color: "transparent"

        Rectangle {
            anchors.fill: parent
            radius: provider.tokens.radiusMedium
            color: provider.tokens.surfaceStrong
            border.color: provider.tokens.border
            border.width: 1
        }

        Column {
            id: menuColumn
            anchors.fill: parent
            anchors.margins: provider.tokens.space
            spacing: 2

            Repeater {
                model: [
                    { label: qsTr("開啟啟動器"), command: "launcher.toggle" },
                    { label: qsTr("組合中心"), command: "composition.open" },
                    { label: qsTr("插件中心"), command: "plugins.open" },
                    { label: qsTr("變更紀錄"), command: "history.open" },
                    { label: qsTr("個人化設定"), command: "personalization.open" },
                    { label: qsTr("鎖定畫面"), session: "lock" },
                    { label: qsTr("登出"), session: "logout" },
                    { label: qsTr("暫停"), session: "suspend" },
                    { label: qsTr("關機"), session: "poweroff" }
                ]

                Rectangle {
                    id: menuItem
                    required property var modelData
                    readonly property bool motionActive: provider.soft && visible && provider.shown && provider.tokens.motionEnabled
                    readonly property real feedbackTarget: !provider.soft || !visible || !provider.shown ? 1
                        : itemArea.pressed ? 0.90 : itemArea.containsMouse || activeFocus ? 0.96 : 1
                    property real feedbackScale: 1
                    readonly property bool motionRunning: menuFeedback.running
                    function retargetFeedback() {
                        menuFeedback.stop();
                        if (!motionActive) { feedbackScale = feedbackTarget; return; }
                        menuFeedback.from = feedbackScale; menuFeedback.to = feedbackTarget; menuFeedback.start();
                    }
                    onFeedbackTargetChanged: retargetFeedback()
                    onMotionActiveChanged: if (!motionActive) { menuFeedback.stop(); feedbackScale = feedbackTarget; }
                    NumberAnimation {
                        id: menuFeedback
                        target: menuItem; property: "feedbackScale"
                        duration: 120
                        easing.type: Easing.OutCubic
                    }
                    readonly property string capabilityId: modelData.session
                        ? "desktop.session." + modelData.session : "desktop.commands.invoke"
                    visible: provider.client && provider.client.capabilityAvailable(capabilityId)
                    width: menuColumn.width
                    height: visible ? 28 : 0
                    radius: provider.tokens.radiusSmall
                    color: itemArea.containsMouse || activeFocus ? provider.tokens.surface : "transparent"
                    activeFocusOnTab: true
                    Accessible.role: Accessible.MenuItem
                    Accessible.name: itemText.text
                    Keys.onReturnPressed: activate()
                    Keys.onSpacePressed: activate()

                    function activate() {
                        if (modelData.session) {
                            provider.session(modelData.session);
                        } else {
                            provider.invoke(modelData.command);
                        }
                    }

                    Text {
                        id: itemText
                        scale: menuItem.feedbackScale
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.left: parent.left
                        anchors.leftMargin: provider.tokens.space
                        text: provider.t(modelData.label)
                        color: provider.tokens.foreground
                        font.pixelSize: provider.tokens.fontBody
                    }

                    Rectangle {
                        anchors.fill: parent
                        radius: parent.radius
                        color: "transparent"
                        border.color: provider.tokens.focus
                        border.width: parent.activeFocus ? 2 : 0
                    }

                    MouseArea {
                        id: itemArea
                        anchors.fill: parent
                        hoverEnabled: true
                        onClicked: parent.activate()
                    }
                }
            }
        }
    }

    /// Tooltip: a popup surface of its own, so it is never clipped by the
    /// panel window's 36 px; themed like the menu, under its control,
    /// clamped to the screen, and pointer input passes through it.
    PopupWindow {
        id: tooltip
        objectName: "panelTooltipWindow"
        readonly property FeedbackButton owner: provider.tooltipOwner
        readonly property point spot: {
            if (!owner || !provider.tooltipShown) return Qt.point(0, 0);
            const bottom = owner.mapToItem(lightPanel, owner.width / 2, owner.height);
            return Qt.point(bottom.x, bottom.y);
        }
        visible: provider.shown && provider.soft && provider.tooltipShown && owner !== null
        anchor.window: panel
        anchor.rect.x: Math.round(Math.max(8, Math.min(panel.width - width - 8, spot.x - width / 2)))
        anchor.rect.y: Math.round(spot.y + 8)
        implicitWidth: Math.ceil(tooltipBox.width)
        implicitHeight: Math.ceil(tooltipBox.height)
        color: "transparent"
        mask: Region {}

        Rectangle {
            id: tooltipBox
            objectName: "panelTooltip"
            width: Math.min(360, tooltipLabel.implicitWidth + 16)
            height: tooltipLabel.height + 10
            radius: provider.tokens.radiusSmall
            color: provider.tokens.surfaceStrong
            border.color: provider.tokens.border
            border.width: 1
            Text {
                id: tooltipLabel
                objectName: "panelTooltipText"
                x: 8; y: 5
                width: parent.width - 16
                wrapMode: Text.Wrap
                text: tooltip.owner ? tooltip.owner.tooltipText : ""
                color: provider.tokens.foreground
                font.pixelSize: provider.tokens.fontSmall
            }
        }
    }
}
