import QtQuick
import QtTest
import Quickshell
import DittoStub
import "../.staged/assistant/shell/jelly" as Jelly
import "../.staged/assistant/shell/chat" as Chat
import "../.staged/capture-data.js" as Data
import "../.staged/assistant/capture-output.js" as Output

// Development fixture captures of the actual Shell components. Session/turn
// ids below are explicit fixtures; no model, Core IPC or real approval runs.
TestCase {
    id: testCase
    name: "AssistantScenes"
    width: 1280
    height: 800
    visible: true
    when: windowShown
    readonly property string outDir: Output.outDir
    property string candidateCaption: ""
    Item {
        id: desktop
        width: 1280
        height: 800
        Jelly.Backdrop { anchors.fill: parent; tokens: tokens }
        Item { id: layer; anchors.fill: parent }
        Text {
            x: 24; y: testCase.candidateCaption ? 44 : 16
            text: "Development fixture · no Core / compositor / model"
            color: tokens.foregroundMuted
            font.pixelSize: 14
        }
        Text {
            x: 32; y: 72
            text: testCase.candidateCaption
            color: tokens.foreground
            font.pixelSize: 18
        }
    }
    Jelly.Tokens { id: tokens }
    QtObject {
        id: client
        property bool online: true
        property var packages: []
        property var windows: []
        property string status: ""
        property var workspaces: [
            { id: "1", name: "1", active: true }, { id: "2", name: "2", active: false },
            { id: "3", name: "3", active: false }, { id: "4", name: "4", active: false }
        ]
        signal changeUpdated(var change)
        signal disconnected()
        function t(text) { return text; }
        function key(text, args) { return text; }
        function capabilityAvailable(name) { return false; }
        function capability(name, args, ok, fail) {
            if (ok) ok(name === "desktop.launcher.list_apps" ? { apps: Data.apps } : {});
        }
        function watchTopics(topics, event, resync, ready, error) {
            ready({ subscription_id: "fixture-subscription" });
        }
    }
    Chat.ConversationState { id: conversation; client: client }
    property var mounted: []
    function mount(path, props, parent) {
        const component = Qt.createComponent(Qt.resolvedUrl("../.staged/assistant/" + path));
        compare(component.status, Component.Ready, component.errorString());
        const object = component.createObject(parent || layer, props);
        verify(object !== null, component.errorString());
        mounted.push(object);
        return object;
    }
    function cleanup() {
        mouseMove(desktop, 640, 400);
        candidateCaption = "";
        for (const object of mounted) {
            if (typeof object.release === "function") object.release();
            object.destroy();
        }
        mounted = [];
        wait(20);
    }
    function provider(file, config) {
        const component = Qt.createComponent(Qt.resolvedUrl("../.staged/providers/" + file));
        compare(component.status, Component.Ready, component.errorString());
        const incubator = component.incubateObject(testCase, { tokens: tokens, client: client, config: config,
            entryId: file, slotName: "", shown: false });
        incubator.forceCompletion();
        const object = incubator.object;
        verify(object !== null, component.errorString());
        mounted.push(object);
        object.shown = true;
        return object;
    }
    // Non-desktop scenes use a geometry fixture; the desktop scene below
    // replaces it with the actual staged provider, just like the Shell mount.
    function defaultDockMount(output) {
        return { binding: { package: "ditto.dock.pill" }, object: { shown: true,
            reservedEdge: "bottom", screen: output, edgeGap: 12, pillThickness: 68 } };
    }
    function test_selected_data() {
        return ["collapsed", "hover", "focus", "expanded", "working-collapsed", "working", "open", "open-collapsed", "reduced-motion", "legacy-theme", "desktop"]
            .map(scene => ({ tag: "D1-56-E1-" + scene, scene: scene }));
    }
    function test_selected(data) {
        StubDesktop.layer = layer;
        StubDesktop.screenWidth = 1280; StubDesktop.screenHeight = 800;
        Quickshell.iconMap = Data.iconMap;
        const scene = data.scene;
        const isWorking = scene.indexOf("working") === 0;
        tokens.appearance = { theme: scene === "legacy-theme" ? "soft-jelly" : "soft-jelly-light",
            tokens: {}, reduced_motion: scene === "reduced-motion" };
        client.online = true;
        conversation.wanted = false;
        conversation.subscriptionId = "";
        conversation.settings = { enabled: true };
        conversation.provider = { available: true, authenticated: true };
        conversation.sessionId = "fixture-fab-session";
        conversation.turn = isWorking ? { turn_id: "fixture-fab-turn", state: "running" } : null;
        conversation.events = [];
        conversation.runtime = null;
        conversation.reconnecting = false;
        conversation.draft = "";
        conversation.streamText = "";
        const output = { name: "fixture-output", width: 1280, height: 800 };
        const surface = mount("shell/assistant/AssistantSurface.qml", {
            tokens: tokens, conversation: conversation, client: client, screen: output,
            entryStyle: "fab", symbolVariant: "ditto", dockMount: defaultDockMount(output)
        });
        const entry = surface.contentItem.children.find(item => typeof item.symbolVariant === "string");
        let chat = null;
        surface.activated.connect(() => {
            conversation.wanted = true;
            const r = surface.contentItem;
            chat = mount("shell/chat/ChatPanel.qml", { tokens: tokens, client: client, conversation: conversation,
                screen: output, entryRect: { x: r.x, y: r.y, width: r.width, height: r.height } });
            chat.closeRequested.connect(() => { chat.visible = false; surface.expanded = false; });
            surface.expanded = true;
        });
        if (["expanded", "working", "open", "open-collapsed", "reduced-motion", "legacy-theme", "desktop"].indexOf(scene) >= 0)
            mouseClick(entry, entry.width / 2, entry.height / 2);
        if (["open", "open-collapsed", "reduced-motion", "legacy-theme"].indexOf(scene) >= 0)
            entry.activate(); // E1 second activation: same compact, no new chat.
        if (scene === "open-collapsed") surface.labelExpanded = false;
        if (isWorking) conversation.wanted = true;
        if (scene === "hover") mouseMove(entry, entry.width / 2, entry.height / 2);
        else mouseMove(desktop, 640, 400);
        if (scene === "focus") entry.forceActiveFocus();
        let dock = null;
        if (scene === "desktop") {
            dock = provider("DockPill.qml", { position: "bottom", pinned: Data.pinned });
            dock.screen = output;
            surface.dockMount = { binding: { package: "ditto.dock.pill" }, object: dock };
            provider("PanelTop.qml", {});
            tryCompare(dock, "appsLoaded", true);
            compare(dock.entries.length, Data.pinned.length);
            const capsule = findChild(layer, "dockCapsule");
            tryVerify(() => capsule.width > capsule.height * 2, 3000, "Dock laid out with icons");
            tryCompare(dock, "reveal", 1);
            tryVerify(() => dock.entries.every(item => !findChild(layer, "dockTile_" + item.appId).motionRunning));
            tryVerify(() => ["panelNetworkIcon", "panelVolumeIcon"].every(name => findChild(layer, name).status !== Image.Loading));
        }
        candidateCaption = "D1 · 56 px · E1 · " + scene
            + "\n點擊 / Enter / Space 展開；hover / focus 僅回饋；Escape 收合"
            + "\nowner 選定（2026-10-19）· 無新增快捷動作 · 無桌布素材";
        tryCompare(findChild(entry, "dittoBodyImage"), "status", Image.Ready);
        tryCompare(entry, "feedbackRunning", false);
        if (chat) tryCompare(findChild(chat.contentItem, "chatPresentationContent"), "opacity", 1);
        // grabImage renders synchronously; wait for layout and the actual
        // finite motion above, rather than waiting for an unrelated swap.
        waitForPolish(desktop);
        const path = outDir + "assistant-" + data.tag + ".png";
        const capture = grabImage(desktop);
        compare(capture.width, 1280); compare(capture.height, 800);
        capture.save(path);
        console.log("ASSISTANT_CAPTURE " + JSON.stringify({ scene: data.tag, file: path,
            evidence_class: "development", fixture: true, presentation: "D1-56-E1",
            symbol: surface.symbolVariant, fab_size: 56, expansion: "E1",
            trigger: "click/Enter/Space; hover/focus feedback only; Escape collapse",
            viewport: [1280,800], scale: 1, compositor: "stub", profile_hash: null,
            renderer: desktop.GraphicsInfo.api === GraphicsInfo.Software ? "software" : "graphics-api-" + desktop.GraphicsInfo.api,
            entry: { x: surface.contentItem.x, y: surface.contentItem.y, width: surface.width, height: surface.height },
            chat: chat ? { x: chat.contentItem.x, y: chat.contentItem.y, width: chat.width, height: chat.height } : null,
            motion: { enabled: tokens.motionEnabled, settled: !entry.feedbackRunning, working_cue: entry.workingCueRunning },
            state_text: entry.statusText, session_id: conversation.sessionId,
            turn_id: conversation.turn ? conversation.turn.turn_id : null, full_desktop: !!dock }));
    }
    function test_scenes_data() {
        const rows = [];
        for (const presentation of ["normal", "legacy"]) {
            for (const scene of ["collapsed", "compact", "full", "approval", "unknown", "offline"]) {
                rows.push({ tag: presentation + "-" + scene, presentation: presentation, scene: scene });
            }
        }
        return rows;
    }
    function test_scenes(data) {
        StubDesktop.layer = layer;
        StubDesktop.screenWidth = 1280; StubDesktop.screenHeight = 800;
        const legacy = data.presentation === "legacy";
        const scene = data.scene;
        const preopen = scene === "collapsed";
        // Normal fixtures retain production motion and wait for finite
        // transitions below. Legacy avatar remains a deliberately static sample.
        tokens.appearance = { theme: legacy ? "soft-jelly" : "soft-jelly-light", tokens: {}, reduced_motion: legacy };
        conversation.wanted = false;
        conversation.subscriptionId = "";
        client.online = scene !== "offline";
        conversation.wanted = !preopen;
        conversation.settings = preopen ? null : { enabled: true };
        conversation.provider = preopen ? null : { available: true, authenticated: true };
        conversation.sessionId = preopen ? "" : "fixture-session-r3";
        conversation.turn = scene === "unknown" ? { turn_id: "fixture-unknown", state: "unknown" }
            : scene === "approval" ? { turn_id: "fixture-approval", state: "awaiting_approval" } : null;
        conversation.draft = preopen ? "" : "尚未送出的草稿 / unsent draft";
        conversation.events = preopen ? [] : [{ seq: 0, type: "user/message", data: { text: "Fixture: adjust the desktop" } }];
        conversation.streamText = "";
        conversation.sessions = [];
        const output = { name: "fixture-output", width: 1280, height: 800 };
        let entryRect;
        let entryControl = null;
        if (legacy) {
            mount("shell/avatar/Avatar.qml", { tokens: tokens, animations: false,
                avatarState: conversation.wanted ? conversation.taskState : "idle", width: 220, height: 220, x: 1028, y: 486 });
            entryRect = { x: 1028, y: 486, width: 220, height: 250 };
        } else {
            const entry = mount("shell/assistant/AssistantSurface.qml", {
                tokens: tokens, conversation: conversation, client: client, screen: output,
                dockMount: defaultDockMount(output),
                entryStyle: "fab", symbolVariant: "ditto", labelExpanded: !preopen, expanded: !preopen
            });
            entryRect = { x: entry.contentItem.x, y: entry.contentItem.y,
                width: entry.implicitWidth, height: entry.implicitHeight };
            entryControl = entry.contentItem.children.find(item => typeof item.symbolVariant === "string");
        }
        let chat = null;
        if (scene === "full") {
            chat = mount("shell/chat/ChatWindow.qml", { tokens: tokens, client: client, conversation: conversation, assistantPresentation: !legacy, x: 620, y: 60 });
        } else if (scene !== "collapsed") {
            chat = mount("shell/chat/ChatPanel.qml", { tokens: tokens, client: client, conversation: conversation,
                screen: output, entryRect: legacy ? null : entryRect });
        }
        if (scene === "approval") {
            mount("shell/chat/ApprovalWindow.qml", { tokens: tokens, client: client, x: 360, y: 240,
                approval: { request_id: "fixture-request", request: { resource: "desktop.config" } } });
        }
        if (entryControl) tryCompare(entryControl, "feedbackRunning", false);
        if (chat && scene !== "full") tryCompare(findChild(chat.contentItem, "chatPresentationContent"), "opacity", 1);
        waitForRendering(desktop);
        const path = outDir + "assistant-" + data.tag + ".png";
        grabImage(desktop).save(path);
        console.log("ASSISTANT_CAPTURE " + JSON.stringify({ scene: data.tag, file: path,
            evidence_class: "development", fixture: true, viewport: [1280,800], scale: 1,
            renderer: desktop.GraphicsInfo.api === GraphicsInfo.Software ? "software" : "graphics-api-" + desktop.GraphicsInfo.api,
            graphics_api: desktop.GraphicsInfo.api, compositor: "stub", profile: data.presentation,
            motion: { enabled: tokens.motionEnabled, settled: true },
            profile_hash: null, session_id: conversation.sessionId, turn_id: conversation.turn ? conversation.turn.turn_id : null,
            operation_ids: [], task_state: conversation.taskState, state_text: conversation.stateText,
            wanted: conversation.wanted, settings_known: !!conversation.settings,
            entry: entryRect, pending_approval: scene === "approval" }));
        // Switching surface never replaces the shared draft, events or turn.
        compare(conversation.draft, preopen ? "" : "尚未送出的草稿 / unsent draft");
        compare(conversation.events.length, preopen ? 0 : 1);
    }
}
