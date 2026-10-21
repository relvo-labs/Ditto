import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import "core"
import "jelly"
import "avatar"
import "assistant"
import "change"
import "centers"
import "chat"

/// Ditto's desktop session (G1). The Shell owns what is on screen: the
/// background, the character, the four centers, the change bar, and the
/// ProviderHost that mounts the replaceable UI providers (panel, dock,
/// launcher, tasks panel, notification area) Core binds in the Profile. What
/// is configured is Core's; the Shell keeps no configuration and writes
/// nothing to disk.
ShellRoot {
    id: root

    /// Core launches the Shell with a single-use token. A reload on a source
    /// change comes back without one and cannot reach Core again, leaving the
    /// desktop with no panel or dock (2026-10-09, the live session ran from a
    /// working tree being edited). Development opts in with DITTO_SHELL_WATCH=1.
    settings.watchFiles: Quickshell.env("DITTO_SHELL_WATCH") === "1"

    Tr {
        id: translator
        locale: providers.appearance && providers.appearance.locale
            ? providers.appearance.locale
            : (Quickshell.env("DITTO_LOCALE") || "zh-TW")
    }

    Tokens {
        id: tokens
        appearance: providers.appearance
    }

    RpcCounter {
        id: rpcCounter
    }

    DittoClient {
        id: client
        counter: rpcCounter
        tr: translator
        participant: providers
        commandHandler: root.runCommand
    }

    /// The conversation the chat surfaces show. Idle until the chat is first
    /// opened: no subscription, no Agent start before that.
    ConversationState {
        id: conversation
        client: client
    }

    ProviderHost {
        id: providers
        client: client
        tokens: tokens
        counter: rpcCounter
        avatarPlacement: root.avatarPlacement
    }

    /// Commands the Shell owns, from `shell.command` (Core decides who owns a
    /// command; a shortcut Core bound arrives here the same way).
    /// What the `focus` control line answers: the centers' focused control
    /// by its accessible name and role, with the accessible names of the
    /// groups it sits in, innermost first. Only names are read; nothing is
    /// pressed and nothing is sent to Core.
    function focusReport() {
        const window = approvalLoader.item || centersLoader.item || chatLoader.item || chatPanelLoader.item;
        if (!window || (window === centersLoader.item && !centers.open)) {
            return { open: false };
        }
        const item = window.focusedItem;
        if (!item) {
            return { open: true, page: centers.page, focused: null };
        }
        const groups = [];
        for (let parent = item.parent; parent; parent = parent.parent) {
            const name = parent.Accessible ? parent.Accessible.name : "";
            if (name && name.length > 0) {
                groups.push(name);
            }
        }
        return {
            open: true,
            page: centers.page,
            focused: {
                name: item.Accessible ? item.Accessible.name : "",
                role: item.Accessible ? item.Accessible.role : -1,
                checked: item.Accessible ? item.Accessible.checked : false,
                enabled: item.enabled,
                groups: groups
            }
        };
    }

    /// What the `tasks` control line answers: what the mounted tasks panel
    /// (`ui.tasks_panel`) holds to show, read from the provider itself, so a
    /// verification run can tell what the panel reflects without asking Core.
    /// Read-only and on demand; nothing is sent to Core.
    function tasksReport() {
        const panel = providers.item("ui.tasks_panel");
        if (!panel) {
            return { mounted: false };
        }
        const open = panel.openTasks || [];
        return {
            mounted: true,
            shown: panel.shown === true,
            unavailable: panel.unavailable === true,
            loaded: !!panel.snapshot,
            open: open.map(task => task.text)
        };
    }

    /// What the `services` control line answers: whether the tasks and
    /// notification-policy services are shown as unavailable, and the exact
    /// product text the surfaces show for it. Read-only.
    function servicesReport() {
        const panel = providers.item("ui.tasks_panel");
        const area = providers.item("ui.notifications");
        return {
            tasks: panel ? { mounted: true, unavailable: panel.unavailable === true, text: panel.headerText || "" } : { mounted: false },
            notification_policy: area ? { mounted: true, unavailable: area.policyUnavailable === true, text: area.policyNotice || "" } : { mounted: false }
        };
    }

    /// What the `status` control line answers: the `ui.status_item` members
    /// as laid out, in order, read from the items themselves (their parent,
    /// size and text), so a run can tell they are on screen
    /// without taking the Shell's report for it. Read-only; nothing is sent.
    function statusReport() {
        const area = providers.statusArea;
        const region = area.region;
        const items = area.mountedItems().map(item => {
            const unit = Object.values(providers.slots).find(found => found.activeItem === item);
            // The first child's text, when it has one (the D-34 items do).
            const label = item.children.length > 0 && typeof item.children[0].text === "string" ? item.children[0].text : "";
            return {
                entry_id: unit && unit.active ? unit.active.binding.entry_id : "",
                package: unit && unit.active ? unit.active.binding.package : "",
                in_region: region !== null && item.parent === region,
                visible: item.visible === true,
                width: Math.round(item.width),
                height: Math.round(item.height),
                text: label
            };
        });
        return {
            region: region === null ? "none" : (area.panelProvider !== null ? "panel" : "strip"),
            region_shown: area.regionShown,
            items: items
        };
    }

    function runCommand(commandId, args) {
        switch (commandId) {
        case "launcher.toggle": {
            const launcher = providers.item("ui.launcher");
            if (launcher && typeof launcher.toggle === "function") {
                if (!launcher.isOpen) {
                    rpcCounter.mark("launcher.open");
                }
                launcher.toggle();
            } else if (launcher && typeof launcher.open === "function") {
                launcher.isOpen ? launcher.close() : launcher.open();
            } else {
                console.log("ditto-shell no launcher is mounted");
            }
            return;
        }
        case "composition.open":
            centers.show("composition");
            return;
        case "plugins.open":
            centers.show("plugins");
            return;
        case "history.open":
            centers.show("history");
            return;
        case "personalization.open":
            centers.show("personalization");
            return;
        case "chat.open":
            root.openChat();
            return;
        case "chat.toggle":
            if (chat.open) {
                root.closeChat();
            } else {
                rpcCounter.mark("chat.open");
                root.openChat();
            }
            return;
        case "ai_settings.open":
            root.openAiSettings();
            return;
        }
        console.log("ditto-shell ignored command " + commandId);
    }

    /// The chat opens beside the character, or as a window when there is no
    /// character to sit beside (AVA-07: every way in works without it).
    property string chatReturnWindow: ""
    property string lastFocusedApplication: ""
    Connections {
        target: client
        function onWindowsChanged() {
            const focused = client.windows.find(window => window.focused);
            if (focused) root.lastFocusedApplication = focused.id;
        }
    }
    ChatFocusReturn {
        id: chatFocusReturn
        client: root.shellClient
        enabled: root.assistantPresentation
        returnWindow: root.chatReturnWindow
        lastFocusedApplication: root.lastFocusedApplication
        chatOpen: chat.open
        blocked: !!approvalLoader.item || centers.open
    }
    function closeChat() {
        chat.open = false;
        chatFocusReturn.restore();
    }
    function openChat(mode) {
        if (!chat.open && assistantPresentation) {
            const previous = client.windows.find(window => window.focused);
            chatReturnWindow = previous ? previous.id : lastFocusedApplication;
        }
        conversation.open();
        chat.mode = mode || (chat.open ? chat.mode : ((assistantLoader.item && assistantLoader.item.visible) || (avatarLoader.item && avatarLoader.item.visible) ? "panel" : "window"));
        chat.open = true;
        // Already open: bring the keyboard back to the message field.
        const surface = chat.mode === "panel" ? chatPanelLoader.item : chatLoader.item;
        if (surface) {
            surface.requestFocus();
        }
    }

    /// What the `chat` control line answers: what the chat shows, read from
    /// the shared conversation state. Read-only; nothing is sent to Core.
    function chatReport() {
        const last = conversation.events.filter(event => event.type === "assistant/message").slice(-1)[0];
        // Not read or failed to read is null (with ai_status), never idle.
        const status = conversation.chatStatus();
        return {
            open: chat.open,
            mode: chat.mode,
            streaming: conversation.streamText.length,
            sessions: conversation.sessions.length,
            draft: conversation.draft,
            state: status.state,
            ai_status: status.ai_status,
            text: status.text,
            enabled: status.enabled,
            connected: status.connected,
            session_id: conversation.sessionId,
            turn_state: conversation.turn ? conversation.turn.state : null,
            events: conversation.events.map(event => event.type),
            changes: conversation.changeIds(),
            answer: last && last.data ? last.data.text : null,
            error: conversation.errorText,
            attached: conversation.attached.map(item => ({ kind: item.kind, label: item.label, bytes: item.bytes }))
        };
    }

    readonly property var shellClient: client
    readonly property var shellConversation: conversation
    readonly property var shellTokens: tokens
    readonly property var shellProviders: providers
    readonly property var avatarSettings: providers.avatar
    readonly property bool assistantPresentation: !!avatarSettings && avatarSettings.presentation === "assistant"
    readonly property bool avatarEnabled: Quickshell.env("DITTO_AVATAR") !== "off"
        && (!avatarSettings || avatarSettings.enabled !== false)
    property bool avatarRecalled: false

    /// The primary output: the one at the top left of the layout. Wayland has
    /// no primary output; Core uses the same rule (crates/ditto-core/src/outputs.rs).
    readonly property var primaryScreen: {
        const screens = Quickshell.screens;
        let best = null;
        for (let i = 0; i < screens.length; i++) {
            const screen = screens[i];
            if (!best || screen.x < best.x || (screen.x === best.x && (screen.y < best.y
                    || (screen.y === best.y && screen.name < best.name)))) {
                best = screen;
            }
        }
        return best;
    }
    /// The output the Profile names, while it is connected.
    readonly property var namedScreen: {
        const wanted = avatarSettings && avatarSettings.output ? avatarSettings.output : "";
        if (wanted.length === 0) {
            return null;
        }
        const screens = Quickshell.screens;
        for (let i = 0; i < screens.length; i++) {
            if (screens[i].name === wanted) {
                return screens[i];
            }
        }
        return null;
    }
    /// Named and connected, or else the primary output: an unplugged output
    /// sends the character to the primary one, and it goes back when the
    /// output returns.
    readonly property var avatarScreen: namedScreen || primaryScreen
    readonly property string avatarCorner: avatarSettings && avatarSettings.corner ? avatarSettings.corner : "bottom_right"

    /// What the character's surface actually is: its screen, its corner and
    /// rectangle on that screen, and whether it is shown. Reported to Core
    /// (shell.report), which answers desktop.panels.list and reads changes
    /// back from it. Read from the surface, not copied from the settings.
    readonly property var avatarPlacement: {
        const surface = root.assistantPresentation ? assistantLoader.item : avatarLoader.item;
        if (!surface || !surface.screen) {
            return { follows_primary: !namedScreen, corner: avatarCorner, x: 0, y: 0, width: 0, height: 0, visible: false };
        }
        const screen = surface.screen;
        const left = surface.anchors.left && !surface.anchors.right;
        const top = surface.anchors.top && !surface.anchors.bottom;
        const width = Math.round(surface.implicitWidth);
        const height = Math.round(surface.implicitHeight);
        return {
            output: screen.name,
            follows_primary: !namedScreen || screen !== namedScreen,
            corner: (top ? "top" : "bottom") + "_" + (left ? "left" : "right"),
            x: Math.round(left ? surface.margins.left : screen.width - surface.margins.right - width),
            y: Math.round(top ? surface.margins.top : screen.height - surface.margins.bottom - height),
            width: width,
            height: height,
            visible: surface.visible
        };
    }
    onAvatarPlacementChanged: placementReport.restart()

    /// Outputs come and go in bursts (a hotplug is several events): one
    /// report after they settle, never one per frame.
    Timer {
        id: placementReport
        interval: 250
        onTriggered: providers.reportPlacement()
    }

    BackgroundFallback {
        providers: root.shellProviders
        tokens: root.shellTokens
    }

    /// The four centers share one window, loaded only while open: closed
    /// centers render nothing and subscribe to nothing (RUN-07).
    QtObject {
        id: centers
        property string page: "composition"
        property bool open: false

        function show(name) {
            page = name;
            open = true;
        }
    }

    LazyLoader {
        id: centersLoader
        active: centers.open

        // `client: client` here would bind the property to itself.
        Centers {
            client: root.shellClient
            tokens: root.shellTokens
            providers: root.shellProviders
            conversation: root.shellConversation
            page: centers.page
            onCloseRequested: centers.open = false
            onPageChanged: centers.page = page
        }
    }

    QtObject {
        id: chat
        property bool open: false
        /// "panel" (beside the character) or "window"; switching changes
        /// only the presentation of the one conversation state.
        property string mode: "panel"
    }

    function openAiSettings() {
        centers.show("ai");
    }

    /// Agent approval requests waiting for this person, oldest first. Each is
    /// answered once through Core (desktop.approvals.decide) and dropped; an
    /// expired one is dropped too (Core already refuses it).
    QtObject {
        id: approvals
        property var pending: []
        property var answered: ({})

        function add(approval) {
            if (!approval.request_id || approval.decision || answered[approval.request_id]
                || pending.some(item => item.request_id === approval.request_id)) {
                return;
            }
            pending = pending.concat([approval]);
            expiry.restart();
        }

        function decide(approval, decision) {
            if (answered[approval.request_id]) {
                return;
            }
            const table = Object.assign({}, answered);
            table[approval.request_id] = decision;
            answered = table;
            pending = pending.filter(item => item.request_id !== approval.request_id);
            client.capability("desktop.approvals.decide", {
                request_id: approval.request_id,
                intent_hash: approval.request.intent_hash,
                decision: decision
            }, null, function (error) {
                console.log("ditto-shell approval refused: " + error.name + " " + error.message);
            });
        }

        property Timer expiry: Timer {
            interval: 1000
            repeat: true
            onTriggered: {
                const now = Date.now();
                approvals.pending = approvals.pending.filter(item => item.expires_at_ms > now);
                running = approvals.pending.length > 0;
            }
        }
    }

    Connections {
        target: client
        function onApprovalRequested(approval) {
            approvals.add(approval);
        }
        /// After a (re)connect or a resync, requests still waiting are read
        /// back from Core: a notification sent while the Shell was away is
        /// not lost.
        function onOnlineChanged() {
            if (client.online) {
                root.refreshApprovals();
            }
        }
        function onResynced() {
            root.refreshApprovals();
        }
    }

    function refreshApprovals() {
        client.capability("desktop.approvals.list", {}, function (result) {
            for (const approval of result.approvals || []) {
                approvals.add(approval);
            }
        });
    }

    LazyLoader {
        id: approvalLoader
        active: approvals.pending.length > 0

        ApprovalWindow {
            client: root.shellClient
            tokens: root.shellTokens
            approval: approvals.pending.length > 0 ? approvals.pending[0] : null
            onDecided: decision => {
                if (approval) {
                    approvals.decide(approval, decision);
                }
            }
        }
    }

    /// The chat exists only while open. Closing it does not stop a running
    /// turn: that is Core's, and only 「停止」 cancels it.
    LazyLoader {
        id: chatLoader
        active: chat.open && chat.mode === "window"

        ChatWindow {
            assistantPresentation: root.assistantPresentation
            client: root.shellClient
            tokens: root.shellTokens
            conversation: root.shellConversation
            counter: rpcCounter
            onCloseRequested: root.closeChat()
            onCollapseRequested: chat.mode = "panel"
            onSettingsRequested: root.openAiSettings()
        }
    }

    LazyLoader {
        id: chatPanelLoader
        active: chat.open && chat.mode === "panel"

        ChatPanel {
            client: root.shellClient
            tokens: root.shellTokens
            conversation: root.shellConversation
            screen: root.avatarScreen
            corner: root.avatarCorner
            avatarHeight: avatarLoader.item ? avatarLoader.item.implicitHeight : 0
            entryRect: root.assistantPresentation && root.avatarPlacement.visible ? root.avatarPlacement : null
            animations: !(root.avatarSettings && root.avatarSettings.animations === false)
            counter: rpcCounter
            onCloseRequested: root.closeChat()
            onExpandRequested: chat.mode = "window"
            onSettingsRequested: root.openAiSettings()
        }
    }

    /// Kept or cancelled here: a preview, or a change with a timed revert.
    LazyLoader {
        id: previewLoader
        active: Object.keys(client.pendingConfirmations).length > 0

        PreviewBar {
            client: root.shellClient
            tokens: root.shellTokens
        }
    }

    LazyLoader {
        id: assistantLoader
        active: root.avatarEnabled && root.assistantPresentation
        AssistantSurface {
            // Owner 2026-10-19: D1 / fixed 56 px / E1 (label, then chat).
            entryStyle: "fab"
            symbolVariant: "ditto"
            dockMount: providers.slots["ui.dock"] ? providers.slots["ui.dock"].active : null
            tokens: root.shellTokens
            client: root.shellClient
            conversation: root.shellConversation
            screen: root.avatarScreen
            corner: root.avatarCorner
            expanded: chat.open
            animations: !(root.avatarSettings && root.avatarSettings.animations === false)
            entryScale: root.avatarSettings && root.avatarSettings.scale > 0
                ? Math.max(0.5, Math.min(2.0, root.avatarSettings.scale)) : 1
            shown: !(root.avatarSettings && root.avatarSettings.hidden === true) || root.avatarRecalled
            onActivated: root.openChat("panel")
        }
    }

    /// `DITTO_AVATAR=off` leaves the character out entirely: EX-05 measures the
    /// desktop with and without it, so "off" means no surface and no timers.
    /// The Profile's `avatar.enabled: false` does the same.
    LazyLoader {
        id: avatarLoader
        active: root.avatarEnabled && !root.assistantPresentation

        PanelWindow {
            id: avatarSurface

            // Inside the loader's component, `tokens: tokens` on the Avatar
            // would bind its own property to itself; resolve the id here.
            readonly property Tokens desktopTokens: tokens
            readonly property real scale: root.avatarSettings && root.avatarSettings.scale > 0
                ? Math.max(0.5, Math.min(2.0, root.avatarSettings.scale)) : 1.0

            /// The Profile's output, or the primary one when it names none or
            /// names one that is unplugged. A corner is always inside its
            /// output's visible area, whatever the output's size.
            screen: root.avatarScreen
            readonly property bool shown: !(root.avatarSettings && root.avatarSettings.hidden === true) || root.avatarRecalled
            visible: shown
            /// An output that goes away takes the layer surface with it, and
            /// the surface stays hidden on the new output although `shown`
            /// never changed. Showing it again is a one-off, not a loop: it
            /// runs only while it should be shown and is not.
            onVisibleChanged: if (!visible && shown) reshow.restart()
            onScreenChanged: if (shown) reshow.restart()

            Timer {
                id: reshow
                interval: 100
                onTriggered: {
                    if (avatarSurface.shown && !avatarSurface.visible) {
                        avatarSurface.visible = false;
                        avatarSurface.visible = Qt.binding(() => avatarSurface.shown);
                        console.log("ditto-shell avatar shown again on " + (avatarSurface.screen ? avatarSurface.screen.name : "no screen"));
                    }
                }
            }
            anchors {
                top: root.avatarCorner.indexOf("top") === 0
                bottom: root.avatarCorner.indexOf("bottom") === 0
                left: root.avatarCorner.indexOf("left") > 0
                right: root.avatarCorner.indexOf("right") > 0
            }
            // Clear of the top panel and the dock, and of the screen edge.
            margins { top: 64; bottom: 64; left: 32; right: 32 }
            implicitWidth: Math.round(220 * scale)
            implicitHeight: Math.round(250 * scale)
            color: "transparent"
            exclusionMode: ExclusionMode.Ignore
            focusable: false
            aboveWindows: true
            WlrLayershell.namespace: "ditto-avatar"

            /// Built from the alpha channel at build time. Without it the
            /// transparent area would swallow clicks meant for the application
            /// underneath.
            mask: Region {
                id: hitRegion
                intersection: Intersection.Combine
            }

            Avatar {
                id: avatar
                anchors.top: parent.top
                anchors.horizontalCenter: parent.horizontalCenter
                width: parent.width
                height: parent.width
                tokens: avatarSurface.desktopTokens
                tr: translator
                animations: !root.avatarSettings || root.avatarSettings.animations !== false
                avatarState: conversation.wanted ? conversation.taskState : "idle"
                onPressed: root.openChat("panel")
            }

            /// The character's state is readable as text from the first day, so the
            /// states added later cannot arrive without their wording.
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.bottom: parent.bottom
                color: tokens.foreground
                font.pixelSize: tokens.fontSmall
                /// Once a conversation was opened, its task state is the
                /// character's; before that the character is just idle.
                text: conversation.wanted ? conversation.stateText : avatar.stateText
                Accessible.role: Accessible.StaticText
                Accessible.name: text
            }

            FrameProbe {}

            /// The mask file is read once at startup, from the shell's own
            /// directory; the shell reads no other file and writes none.
            FileView {
                id: maskFile
                path: Qt.resolvedUrl("avatar/layers/hit-mask.json").toString().replace("file://", "")
                blockLoading: true
            }

            Component.onCompleted: {
                const mask = JSON.parse(maskFile.text());
                const component = Qt.createComponent(Qt.resolvedUrl("avatar/MaskRegion.qml"));
                const regions = [];
                for (const rectangle of mask.rectangles) {
                    // Bound, not copied: the loaded surface may not have
                    // its final size yet when this runs.
                    regions.push(component.createObject(hitRegion, {
                        x: Qt.binding(() => Math.round(rectangle.x * avatar.width)),
                        y: Qt.binding(() => Math.round(rectangle.y * avatar.height)),
                        width: Qt.binding(() => Math.max(1, Math.round(rectangle.width * avatar.width))),
                        height: Qt.binding(() => Math.max(1, Math.round(rectangle.height * avatar.height)))
                    }));
                }
                hitRegion.regions = regions;
                console.log("ditto-shell hit mask rectangles=" + regions.length);
            }
        }
    }

    /// The shell's control path: the compositor's keybindings write one line
    /// here, and so does the verification script. `workspace` takes exactly the
    /// same route as a click on the panel, which is what makes the request
    /// count per explicit command measurable.
    ///
    ///   ping <n>        → pong <n>, from this (the UI) thread, at once: the
    ///                     supervisor's liveness check (crates/ditto-supervisor)
    ///   recall          bring the character back when it is covered or hidden
    ///   workspace <id>  the same capability call as a click on the panel
    ///   command <id>    run a Shell-owned command locally (development and
    ///                     verification; the product path is `shell.command`)
    ///   focus           → one JSON line: the accessible name and role of the
    ///                     control with keyboard focus in the centers, and the
    ///                     names of the groups around it. Read-only; a keyboard
    ///                     verification run uses it to know where Tab went
    ///   services        → one JSON line: whether the tasks and notification-
    ///                     policy services are shown as unavailable, with the
    ///                     text the surfaces show. Read-only
    ///   tasks           → one JSON line: whether a tasks panel is mounted and
    ///                     the open tasks it holds to show. Read-only
    ///   chat            → one JSON line: the chat's task state and text, the
    ///                     conversation's event types, change ids and last
    ///                     answer, read from the shared state. Read-only
    ///   chat-send <text> open the chat and send <text> as if typed and
    ///                     submitted with Enter
    ///   chat-attach <clipboard|capture|file PATH>
    ///                     attach context as the chat's buttons do
    ///   status          → one JSON line: where the status items are placed
    ///                     (the panel's region or the Shell's strip) and each
    ///                     item in order, read from the items. Read-only
    SocketServer {
        active: true
        path: (Quickshell.env("DITTO_RUNTIME_DIR")
            || ((Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/ditto")) + "/shell.sock"
        handler: Socket {
            id: connection
            parser: SplitParser {
                splitMarker: "\n"
                onRead: line => {
                    const command = line.trim().split(" ");
                    if (command[0] === "ping" && command.length === 2) {
                        connection.write("pong " + command[1] + "\n");
                        connection.flush();
                    } else if (command[0] === "recall") {
                        root.avatarRecalled = true;
                        if (avatarLoader.item) {
                            avatarLoader.item.aboveWindows = true;
                        }
                        console.log("ditto-shell avatar recalled");
                    } else if (command[0] === "workspace" && command.length === 2) {
                        client.activateWorkspace(command[1]);
                    } else if (command[0] === "command" && command.length === 2) {
                        root.runCommand(command[1], {});
                    } else if (command[0] === "focus") {
                        connection.write(JSON.stringify(root.focusReport()) + "\n");
                        connection.flush();
                    } else if (command[0] === "generated") {
                        const panels=Object.values(providers.slots).filter(unit=>unit.activeItem && unit.activeItem.slotName==="ui.generated_panel").map(unit=>unit.activeItem.observation());
                        connection.write(JSON.stringify(panels)+"\n");connection.flush();
                    } else if (command[0] === "generation-management") {
                        // Read-only diagnostics of the actual center's text.
                        const rows=[];
                        function visit(node) {
                            if (!node) return;
                            if ((node.objectName || "").indexOf("generation")===0 && typeof node.text==="string") rows.push({name:node.objectName,text:node.text,visible:node.visible,width:node.width,height:node.height});
                            for (const child of (node.children || [])) visit(child);
                        }
                        visit(centersLoader.item ? centersLoader.item.diagnosticRoot : null);
                        connection.write(JSON.stringify(rows)+"\n");connection.flush();
                    } else if (command[0] === "services") {
                        connection.write(JSON.stringify(root.servicesReport()) + "\n");
                        connection.flush();
                    } else if (command[0] === "tasks") {
                        connection.write(JSON.stringify(root.tasksReport()) + "\n");
                        connection.flush();
                    } else if (command[0] === "chat") {
                        connection.write(JSON.stringify(root.chatReport()) + "\n");
                        connection.flush();
                    } else if (command[0] === "chat-mode" && command.length === 2) {
                        // The same route as the 展開／收合 buttons.
                        chat.mode = command[1] === "window" ? "window" : "panel";
                    } else if (command[0] === "chat-send" && command.length > 1) {
                        // The same route as typing and pressing Enter.
                        root.openChat();
                        conversation.draft = line.trim().slice("chat-send ".length);
                        conversation.send();
                    } else if (command[0] === "chat-attach" && command.length >= 2) {
                        // The same route as the attachment buttons (and, for
                        // a file, the path the file dialog returns).
                        root.openChat();
                        conversation.attach(command[1], command.length > 2 ? line.trim().split(" ").slice(2).join(" ") : "");
                    } else if (command[0] === "status") {
                        connection.write(JSON.stringify(root.statusReport()) + "\n");
                        connection.flush();
                    } else {
                        console.log("ditto-shell ignored control line");
                    }
                }
            }
        }
    }

    Component.onCompleted: console.log("ditto-shell started")
}
