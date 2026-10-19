import QtQuick
import QtTest
import DittoStub
import "../.staged/assistant/shell/jelly" as Jelly
import "../.staged/assistant/shell/chat" as Chat

TestCase {
    id: testCase
    name: "AssistantFlowAndLegacy"
    width: 1280
    height: 800
    visible: true
    when: windowShown
    Item { id: layer; width: 1280; height: 800 }
    Jelly.Tokens { id: tokens }
    QtObject {
        id: client
        property bool online: true
        property var packages: []
        property int writes: 0
        property var windows: [{ id: "X", focused: true }, { id: "Y", focused: false }]
        property string focusedApplication: "X"
        property var focusCalls: []
        function focusWindow(id) { focusCalls = focusCalls.concat([id]); focusedApplication = id; }
        signal changeUpdated(var change)
        signal disconnected()
        function t(text) { return text; }
        function key(text, args) { return text; }
        function capabilityAvailable(name) { return false; }
        function capability(name, args, ok, fail) { writes++; }
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
    function init() {
        StubDesktop.layer = layer;
        client.writes = 0;
        tokens.appearance = { theme: "soft-jelly", reduced_motion: true, tokens: {} };
        conversation.wanted = true;
        conversation.settings = { enabled: true };
        conversation.provider = { available: true, authenticated: true };
        conversation.events = [];
        conversation.turn = null;
    }
    function cleanup() {
        for (const object of mounted) object.destroy();
        mounted = []; wait(20);
    }
    function test_fresh_entry_flow() {
        conversation.wanted = false;
        conversation.settings = null;
        conversation.provider = null;
        const surface = mount("shell/assistant/AssistantSurface.qml", { tokens: tokens, client: client,
            conversation: conversation, screen: { name: "fixture", width: 1280, height: 800 } });
        const entry = surface.contentItem.children.find(item => typeof item.symbolVariant === "string");
        verify(!!entry);
        compare(entry.Accessible.description, "待命中");
        compare(client.writes, 0);
    }
    function test_default_button_pixels_unchanged_data() {
        return [{ tag: "light", theme: "soft-jelly-light" }, { tag: "legacy", theme: "soft-jelly" },
            { tag: "absent", theme: undefined }];
    }
    function test_default_button_pixels_unchanged(data) {
        tokens.appearance = { theme: data.theme, tokens: {}, reduced_motion: true };
        const props = { tokens: tokens, client: client, conversation: conversation, width: 218, height: 54 };
        const base = mount("baseline/shell/assistant/AssistantEntry.qml", props);
        verify(waitForRendering(base));
        const before = grabImage(layer);
        base.destroy(); mounted = []; wait(1);
        const current = mount("shell/assistant/AssistantEntry.qml", props);
        verify(waitForRendering(current));
        verify(before.equals(grabImage(layer)), "legacy capsule pixels match de8d617");
        compare(current.entryStyle, "capsule");
        compare(current.symbolVariant, "neutral");
    }
    function test_focus_return_respects_application_switch() {
        client.focusCalls = [];
        client.focusedApplication = "X";
        const policy = mount("shell/chat/ChatFocusReturn.qml", { client: client,
            returnWindow: "X", lastFocusedApplication: "X", chatOpen: true });
        // Open from X, switch to Y while the panel stays open, then close.
        client.focusedApplication = "Y";
        policy.lastFocusedApplication = "Y";
        policy.chatOpen = false;
        policy.restore();
        wait(1);
        compare(client.focusedApplication, "Y");
        compare(client.focusCalls.length, 0);

        // Returning to X is allowed when focus has not moved to another app.
        policy.lastFocusedApplication = "X";
        policy.restore();
        tryCompare(client, "focusedApplication", "X");
        compare(client.focusCalls.length, 1);

        // A switch after scheduling must also preserve Y.
        client.focusCalls = [];
        policy.restore();
        client.focusedApplication = "Y";
        policy.lastFocusedApplication = "Y";
        wait(1);
        compare(client.focusedApplication, "Y");
        compare(client.focusCalls.length, 0);

        policy.lastFocusedApplication = "X";
        policy.blocked = true; // approval/center retains ownership
        policy.restore();
        wait(1);
        compare(client.focusCalls.length, 0);
        policy.blocked = false;
        policy.restore();
        policy.chatOpen = true; // reopened before the deferred callback
        wait(1);
        compare(client.focusCalls.length, 0);
    }
    function test_legacy_pixels_and_geometry_data() {
        return ["bottom_right", "bottom_left", "top_right", "top_left"].map(corner => ({ tag: corner, corner: corner }));
    }
    function test_legacy_pixels_and_geometry(data) {
        const props = { tokens: tokens, client: client, conversation: conversation, corner: data.corner,
            screen: { name: "fixture", width: 1280, height: 800 } };
        const base = mount("legacy/chat/ChatPanel.qml", props);
        wait(30); waitForRendering(layer);
        const before = grabImage(layer);
        const geometry = [base.implicitWidth, base.implicitHeight, base.margins.top, base.margins.bottom, base.margins.left, base.margins.right];
        base.destroy(); mounted = []; wait(30);
        const current = mount("shell/chat/ChatPanel.qml", props);
        wait(30); waitForRendering(layer);
        verify(before.equals(grabImage(layer)), "legacy ChatPanel pixels match 25c0b72");
        compare([current.implicitWidth, current.implicitHeight, current.margins.top, current.margins.bottom, current.margins.left, current.margins.right], geometry);
    }
    function test_actual_entry_geometry_all_corners() {
        for (const corner of ["bottom_right", "bottom_left", "top_right", "top_left"]) {
            const top = corner.indexOf("top") === 0;
            const left = corner.indexOf("left") > 0;
            const entry = { x: left ? 32 : 1030, y: top ? 64 : 714, width: 218, height: 54 };
            const panel = mount("shell/chat/ChatPanel.qml", { tokens: tokens, client: client, conversation: conversation,
                screen: { name: "fixture-output-2", width: 1280, height: 800 }, corner: corner, entryRect: entry });
            compare(panel.margins.top, entry.y + entry.height + 8);
            compare(panel.margins.bottom, 800 - entry.y + 8);
            compare(top ? panel.anchors.top : panel.anchors.bottom, true);
            compare(left ? panel.anchors.left : panel.anchors.right, true);
            verify(panel.implicitHeight > 0);
        }
    }
    function test_scaled_entry_region_and_hidden() {
        for (const scale of [0.5, 1, 2]) {
            const entry = mount("shell/assistant/AssistantSurface.qml", { tokens: tokens, client: client,
                conversation: conversation, entryScale: scale,
                screen: { name: "fixture-output", width: 800, height: 600 } });
            compare(entry.mask.item.width, entry.implicitWidth);
            compare(entry.mask.item.height, entry.implicitHeight);
            verify(!entry.mask.contains(1, 1));
            verify(entry.mask.contains(entry.implicitWidth / 2, entry.implicitHeight / 2));
            entry.shown = false;
            compare(entry.visible, false);
        }
    }
    function test_fab_region_and_e1_same_compact() {
        const output = { name: "fixture", width: 1280, height: 800 };
        const surface = mount("shell/assistant/AssistantSurface.qml", { tokens: tokens, client: client,
            conversation: conversation, screen: output, entryStyle: "fab", symbolVariant: "ditto" });
        for (const scale of [0.5, 1, 2]) {
            surface.entryScale = scale;
            compare(surface.implicitWidth, 56 * scale);
            compare(surface.implicitHeight, 56 * scale);
            checkFabRegion(surface);
        }
        surface.entryScale = 1;
        const entry = surface.contentItem.children.find(item => typeof item.symbolVariant === "string");
        const bodyImage = findChild(entry, "dittoBodyImage");
        tryCompare(bodyImage, "status", Image.Ready);
        compare(bodyImage.sourceSize.width, Math.ceil(35 * 3 * bodyImage.Screen.devicePixelRatio));
        conversation.draft = "fab draft";
        conversation.streamText = "fab stream";
        conversation.events = [{ type: "assistant/message", data: { text: "fab history" } }];
        conversation.turn = { turn_id: "fab-approval", state: "awaiting_approval" };
        let compact = null;
        surface.activated.connect(() => {
            const r = surface.contentItem;
            compact = mount("shell/chat/ChatPanel.qml", { tokens: tokens, client: client, conversation: conversation,
                screen: output, entryRect: { x: r.x, y: r.y, width: r.width, height: r.height } });
            compact.closeRequested.connect(() => { compact.visible = false; surface.expanded = false; });
            surface.expanded = true;
        });
        entry.forceActiveFocus();
        keyClick(Qt.Key_Space);
        compare(compact, null); // E1 first expands the label, without reads/writes.
        compare(surface.labelExpanded, true);
        for (const scale of [0.5, 1, 2]) {
            surface.entryScale = scale;
            compare(surface.implicitWidth, Math.round(entry.implicitWidth * scale));
            compare(surface.implicitHeight, 56 * scale);
            verify(surface.implicitWidth > surface.implicitHeight);
            checkFabRegion(surface);
        }
        surface.entryScale = 1;
        keyClick(Qt.Key_Enter);
        verify(compact !== null);
        compare(compact.conversation, conversation);
        compare(compact.contentItem.y + compact.height + 8, surface.contentItem.y);
        const body = findChild(compact.contentItem, "chatPresentationContent");
        body.focusInput(); keyClick(Qt.Key_Escape);
        compare(compact.visible, false);
        compare(conversation.turn.state, "awaiting_approval");
        compare(conversation.draft, "fab draft");
        compare(conversation.streamText, "fab stream");
        compare(conversation.events.length, 1);
        compare(client.writes, 0);
    }
    function checkFabRegion(surface) {
        compare(surface.mask.item.width, surface.implicitWidth);
        compare(surface.mask.item.height, surface.implicitHeight);
        const w = surface.implicitWidth, h = surface.implicitHeight;
        verify(!surface.mask.contains(1, 1));
        verify(!surface.mask.contains(w - 1, 1));
        verify(!surface.mask.contains(1, h - 1));
        verify(!surface.mask.contains(w - 1, h - 1));
        verify(surface.mask.contains(w / 2, h / 2));
        verify(!surface.mask.contains(w, h / 2));
    }
    function test_switch_keeps_draft_stream_history_approval_and_escape() {
        conversation.draft = "unsent fixture";
        conversation.streamText = "fixture stream";
        conversation.events = [{ type: "assistant/message", data: { text: "fixture history" } }];
        conversation.turn = { turn_id: "fixture-approval", state: "awaiting_approval" };
        const compact = mount("shell/chat/ChatPanel.qml", { tokens: tokens, client: client, conversation: conversation });
        compact.destroy(); mounted = []; wait(20);
        const full = mount("shell/chat/ChatWindow.qml", { tokens: tokens, client: client, conversation: conversation });
        compare(conversation.draft, "unsent fixture");
        compare(conversation.streamText, "fixture stream");
        compare(conversation.events.length, 1);
        compare(conversation.turn.state, "awaiting_approval");
        const body = full.children.find(child => typeof child.handleEscape === "function");
        verify(!!body);
        const spy = Qt.createQmlObject('import QtTest; SignalSpy { signalName: "closeRequested" }', testCase);
        spy.target = body;
        verify(!body.handleEscape(true)); compare(spy.count, 0);
        body.focusInput(); keyClick(Qt.Key_Escape); compare(spy.count, 1);
        compare(client.writes, 0); // neither collapse nor Escape cancels the turn
        compare(conversation.turn.state, "awaiting_approval");
        spy.destroy();
    }
    function test_approval_escape_remains_rejection() {
        const approval = mount("shell/chat/ApprovalWindow.qml", { tokens: tokens, client: client,
            approval: { request_id: "fixture", request: { resource: "desktop.config" } } });
        const spy = Qt.createQmlObject('import QtTest; SignalSpy { signalName: "decided" }', testCase);
        spy.target = approval;
        // The original approval button owns initial focus; keyboard Escape
        // bubbles to the existing root and returns rejected.
        keyClick(Qt.Key_Escape);
        compare(spy.count, 1); compare(spy.signalArguments[0][0], "rejected");
        spy.destroy();
    }
}
