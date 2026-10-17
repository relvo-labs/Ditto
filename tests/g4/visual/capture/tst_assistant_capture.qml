import QtQuick
import QtTest
import DittoStub
import "../.staged/assistant/shell/jelly" as Jelly
import "../.staged/assistant/shell/chat" as Chat

// Development fixture captures of the actual Shell components. Session/turn
// ids below are explicit fixtures; no model, Core IPC or real approval runs.
TestCase {
    id: testCase
    name: "AssistantScenes"
    width: 1280
    height: 800
    visible: true
    when: windowShown
    readonly property string outDir: Qt.resolvedUrl("../.staged/out/").toString().replace("file://", "")
    Item {
        id: desktop
        width: 1280
        height: 800
        Jelly.Backdrop { anchors.fill: parent; tokens: tokens }
        Item { id: layer; anchors.fill: parent }
        Text {
            x: 24; y: 16
            text: "Development fixture · no Core / compositor / model"
            color: tokens.foregroundMuted
            font.pixelSize: 14
        }
    }
    Jelly.Tokens { id: tokens }
    QtObject {
        id: client
        property bool online: true
        property var packages: []
        signal changeUpdated(var change)
        signal disconnected()
        function t(text) { return text; }
        function key(text, args) { return text; }
        function capabilityAvailable(name) { return false; }
        function capability(name, args, ok, fail) { if (ok) ok({}); }
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
        for (const object of mounted) object.destroy();
        mounted = [];
        wait(20);
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
                tokens: tokens, conversation: conversation, client: client, screen: output
            });
            entryRect = { x: 1280 - 32 - entry.implicitWidth, y: 800 - 32 - entry.implicitHeight,
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
        if (entryControl) tryCompare(entryControl.children[0], "scale", 1);
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
