import QtQuick
import QtTest
import DittoStub
import "../.staged/assistant/shell/jelly" as Jelly
import "../.staged/assistant/shell/chat" as Chat
import "../.staged/capture-data.js" as Data

// Rendered geometry/pixel regressions for owner-selected D1 / 56 / E1.
// Core, output and layer shell are fixtures; no real IPC or model.
TestCase {
    id: testCase
    name: "AssistantRepair"
    width: 1280; height: 800
    visible: true
    when: windowShown
    Item {
        id: desktop
        width: 1280; height: 800
        Jelly.Backdrop { anchors.fill: parent; tokens: tokens }
        Item { id: layer; anchors.fill: parent }
    }
    Jelly.Tokens { id: tokens }
    QtObject {
        id: client
        property bool online: true
        property var packages: []
        property var windows: []
        function t(text) { return text; }
        function key(text, args) { return text; }
        function capabilityAvailable(name) { return false; }
        function capability(name, args, ok, fail) {
            if (name === "desktop.launcher.list_apps" && ok) ok({ apps: Data.apps });
        }
        function watchTopics(topics, event, resync, ready, error) { ready({ subscription_id: "repair-fixture" }); }
        signal disconnected()
        signal changeUpdated(var change)
    }
    Chat.ConversationState { id: conversation; client: client }
    property var mounted: []
    function mount(path, props) {
        const c = Qt.createComponent(Qt.resolvedUrl("../.staged/assistant/" + path));
        compare(c.status, Component.Ready, c.errorString());
        const o = c.createObject(layer, props);
        verify(o !== null, c.errorString()); mounted.push(o); return o;
    }
    function init() {
        StubDesktop.layer = layer; StubDesktop.screenWidth = 1280; StubDesktop.screenHeight = 800;
        tokens.appearance = { theme: "soft-jelly-light", tokens: {}, reduced_motion: true };
        conversation.wanted = true;
        conversation.settings = { enabled: true };
        conversation.provider = { available: true, authenticated: true };
        conversation.events = []; conversation.turn = null; conversation.reconnecting = false;
    }
    function cleanup() {
        for (const o of mounted) { if (typeof o.release === "function") o.release(); o.destroy(); }
        mounted = []; wait(20);
    }
    function surface() {
        return mount("shell/assistant/AssistantSurface.qml", { tokens: tokens, client: client,
            conversation: conversation, screen: { name: "fixture", width: 1280, height: 800 },
            entryStyle: "fab", symbolVariant: "ditto" });
    }
    function control(s) { return s.contentItem.children.find(o => typeof o.symbolVariant === "string"); }
    function luminance(c) {
        function channel(v) { return v <= 0.04045 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4); }
        return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b);
    }
    function contrast(a, b) {
        return (Math.max(luminance(a), luminance(b)) + 0.05) / (Math.min(luminance(a), luminance(b)) + 0.05);
    }
    function test_symbol_edge_contrast_data() {
        return [{ tag: "light", theme: "soft-jelly-light", working: false },
            { tag: "working", theme: "soft-jelly-light", working: true },
            { tag: "legacy", theme: "soft-jelly", working: false }];
    }
    function test_symbol_edge_contrast(data) {
        tokens.appearance = { theme: data.theme, tokens: {}, reduced_motion: true };
        const s = surface(), entry = control(s), symbol = entry.children[0];
        tryCompare(findChild(entry, "dittoBodyImage"), "status", Image.Ready);
        if (data.working) {
            entry.animations = false;
            conversation.turn = { turn_id: "fixture-working", state: "running" };
            entry.workLevel = 0.65; // darkest pulse phase must retain the edge.
        }
        verify(waitForRendering(entry));
        const pixels = grabImage(desktop);
        const origin = entry.mapToItem(desktop, 0, 0);
        const y = Math.round(origin.y + entry.height / 2);
        const edge = pixels.pixel(Math.ceil(origin.x + symbol.x + 1), y);
        const fill = pixels.pixel(Math.floor(origin.x + symbol.x - 4), y);
        const ratio = contrast(edge, fill);
        console.log("REPAIR_MEASURE " + JSON.stringify({ defect: "a", theme: data.theme, working: data.working, edge: String(edge), fill: String(fill), contrast: ratio }));
        verify(ratio >= 3, "symbol edge against capsule fill >= 3:1");
    }
    function test_dock_alignment_data() { return [{ tag: "collapsed", expanded: false }, { tag: "label", expanded: true }]; }
    function test_dock_alignment(data) {
        const s = surface(); s.labelExpanded = data.expanded;
        const c = Qt.createComponent(Qt.resolvedUrl("../.staged/providers/DockPill.qml"));
        compare(c.status, Component.Ready, c.errorString());
        const incubator = c.incubateObject(testCase, { tokens: tokens, client: client,
            config: { position: "bottom", pinned: Data.pinned }, shown: false });
        incubator.forceCompletion(); const dock = incubator.object; mounted.push(dock); dock.shown = true;
        const capsule = findChild(layer, "dockCapsule");
        tryVerify(() => capsule.width > capsule.height * 2);
        const dockCentre = capsule.mapToItem(desktop, capsule.width / 2, capsule.height / 2).y;
        const fabCentre = s.contentItem.y + s.height / 2;
        console.log("REPAIR_MEASURE " + JSON.stringify({ defect: "b", expanded: data.expanded, fab_centre: fabCentre,
            dock_centre: dockCentre, difference: fabCentre - dockCentre, right_margin: 1280 - s.contentItem.x - s.width }));
        verify(Math.abs(fabCentre - dockCentre) <= 1, "FAB aligned to actual default Dock capsule centre");
        compare(1280 - s.contentItem.x - s.width, 32);
    }
    function test_open_state_data() {
        return [{ tag: "light", theme: "soft-jelly-light", reduced: false },
            { tag: "reduced", theme: "soft-jelly-light", reduced: true }, { tag: "legacy", theme: "soft-jelly", reduced: true }];
    }
    function test_open_state(data) {
        tokens.appearance = { theme: data.theme, tokens: {}, reduced_motion: data.reduced };
        const s = surface(), entry = control(s); s.labelExpanded = true;
        entry.settleMotion();
        verify(waitForRendering(entry));
        const closed = grabImage(desktop), description = entry.Accessible.description;
        s.expanded = true; entry.settleMotion();
        verify(waitForRendering(entry));
        const changed = !closed.equals(grabImage(desktop));
        console.log("REPAIR_MEASURE " + JSON.stringify({ defect: "c", theme: data.theme, reduced: data.reduced,
            pixel_changed: changed, before_description: description, after_description: entry.Accessible.description }));
        verify(changed);
        verify(entry.Accessible.description !== description, "open state exposed as text to readers");
        const ring = findChild(entry, "assistantOpenRing");
        verify(ring.visible); compare(ring.border.width, 2);
        verify(ring.width < entry.width); // second outline, not colour alone
        s.expanded = false;
        compare(entry.Accessible.description, description);
    }
    function test_e1_compact_suggestion_padding() {
        const s = surface(), entry = control(s);
        let chat = null;
        s.activated.connect(() => {
            const r = s.contentItem;
            chat = mount("shell/chat/ChatPanel.qml", { tokens: tokens, client: client, conversation: conversation,
                screen: s.screen, entryRect: { x: r.x, y: r.y, width: r.width, height: r.height } });
        });
        entry.activate(); compare(chat, null); entry.activate(); verify(chat !== null);
        const body = findChild(chat.contentItem, "chatPresentationContent");
        const examples = body.children[0].children.find(o => o.items !== undefined && o.pill !== undefined);
        const buttons = examples.children.filter(o => o.kind === "subtle");
        compare(buttons.length, 3);
        const gutters = buttons.map(o => {
            const p = o.mapToItem(body, 0, 0);
            const label = o.children.find(item => item.visible && item.wrapMode === Text.WordWrap);
            const textRight = label ? label.mapToItem(body, label.width, 0).x : p.x + o.width;
            return { text: o.Accessible.name, right_gutter: body.width - p.x - o.width,
                text_right_gutter: body.width - textRight, wrapped: label ? label.lineCount : 1 };
        });
        console.log("REPAIR_MEASURE " + JSON.stringify({ defect: "d", body_width: body.width, required_gutter: tokens.spaceWide, suggestions: gutters }));
        for (const row of gutters) verify(row.right_gutter >= tokens.spaceWide, "E1 suggestion button inside compact right padding");
    }
}
