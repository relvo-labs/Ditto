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
    // A third provider opts in with only the public geometry property.
    Component {
        id: thirdDock
        QtObject { property var edgeGeometry: ({ version: 1, output: "fixture", edge: "bottom", visible: true, centreInset: 50 }) }
    }
    property var mounted: []
    function mount(path, props) {
        const c = Qt.createComponent(Qt.resolvedUrl("../.staged/assistant/" + path));
        compare(c.status, Component.Ready, c.errorString());
        const o = c.createObject(layer, props);
        verify(o !== null, c.errorString()); mounted.push(o); return o;
    }
    function init() {
        failOnWarning(/Binding loop detected/);
        StubDesktop.layer = layer; StubDesktop.screenWidth = 1280; StubDesktop.screenHeight = 800;
        client.online = true;
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
    function test_sizing_without_binding_loops_data() {
        return [{ tag: "capsule", style: "capsule", labelled: true, width: 218, height: 54 },
            { tag: "fab", style: "fab", labelled: false, width: 56, height: 56 },
            { tag: "fab-label", style: "fab", labelled: true, width: 195, height: 56 }];
    }
    function test_sizing_without_binding_loops(data) {
        // Mount after init's warning guard: construction warnings must fail too.
        const s = mount("shell/assistant/AssistantSurface.qml", { tokens: tokens, client: client,
            conversation: conversation, screen: { name: "fixture", width: 1280, height: 800 },
            entryStyle: data.style, labelExpanded: data.style === "fab" && data.labelled });
        const entry = control(s);
        s.dockMount = { binding: { package: "ditto.dock.pill" }, object: {
            edgeGeometry: { version: 1, output: s.screen.name, edge: "bottom", visible: true, centreInset: 46 } } };
        for (const scale of [1, 1.01, 1.25, 1.5, 1.64, 1]) {
            s.entryScale = scale;
            for (const state of [null, "running", "awaiting_approval", "succeeded", "failed", "unknown", "cancelled"]) {
                conversation.turn = state ? { turn_id: "sizing-fixture", state: state } : null;
                conversation.reconnecting = state === "unknown";
                client.online = state !== "cancelled";
                verify(waitForRendering(entry));
                compare(entry.implicitWidth, data.width);
                compare(entry.implicitHeight, data.height);
                const w = Math.round(data.width * scale), h = Math.round(data.height * scale);
                compare(s.implicitWidth, w); compare(s.implicitHeight, h);
                compare(entry.width, w / scale); compare(entry.height, h / scale);
                const inset = data.style === "fab" ? 46 : -1;
                compare(s.dockCentreInset, inset);
                const margin = inset >= h / 2 ? inset - h / 2 : 32;
                compare(s.bottomMargin, margin); compare(s.margins.bottom, Math.floor(margin));
                compare(s.contentItem.x, 1280 - 32 - w);
                compare(s.contentItem.y, 800 - Math.floor(margin) - h);
                compare(s.mask.item.width, w); compare(s.mask.item.height, h);
                compare(s.mask.radius, Math.floor(h / 2));
                verify(!s.mask.contains(1, 1)); verify(!s.mask.contains(w - 1, h - 1));
                verify(s.mask.contains(w / 2, h / 2));
                const area = entry.children.find(o => o.cursorShape !== undefined);
                verify(!area.contains(Qt.point(1, 1)));
                verify(area.contains(Qt.point(entry.width / 2, entry.height / 2)));
            }
        }
    }
    function test_font_resize_without_binding_loops() {
        const s = surface(), entry = control(s);
        s.labelExpanded = true;
        for (const fontScale of [2, 0.75, 1.5, 1]) {
            tokens.appearance = { theme: "soft-jelly-light", tokens: { font_scale: fontScale }, reduced_motion: true };
            verify(waitForRendering(entry));
            const height = s.implicitHeight;
            verify(waitForRendering(entry));
            compare(s.implicitHeight, height);
        }
    }
    function test_width_sensitive_text_measurement_without_binding_loops() {
        const s = surface(), entry = control(s);
        s.labelExpanded = true;
        const column = entry.children.find(o => o.spacing !== undefined);
        const status = column.children.find(o => o.elide === Text.ElideRight);
        // Diagnostic stress fixture, not the shipped single-line presentation:
        // force width-sensitive text layout to expose the height -> x -> width
        // -> text measurement cycle even with the offscreen layer-shell double.
        status.wrapMode = Text.WordWrap;
        tokens.appearance = { theme: "soft-jelly-light", tokens: { font_scale: 2 }, reduced_motion: true };
        verify(waitForRendering(entry));
        const height = s.implicitHeight;
        verify(waitForRendering(entry));
        compare(s.implicitHeight, height);
    }
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
    function test_dock_alignment_data() {
        const rows = [];
        for (const file of ["DockPill.qml", "DockBottom.qml"])
            for (const expanded of [false, true]) rows.push({ tag: file + (expanded ? "-label" : "-circle"), file: file, expanded: expanded });
        return rows;
    }
    function test_dock_alignment(data) {
        const s = surface(); s.labelExpanded = data.expanded;
        const c = Qt.createComponent(Qt.resolvedUrl("../.staged/providers/" + data.file));
        compare(c.status, Component.Ready, c.errorString());
        const incubator = c.incubateObject(testCase, { tokens: tokens, client: client,
            config: { position: "bottom", pinned: Data.pinned }, shown: false });
        incubator.forceCompletion(); const dock = incubator.object; mounted.push(dock); dock.shown = true;
        dock.screen = s.screen;
        s.dockMount = { object: dock };
        const capsule = findChild(layer, data.file === "DockPill.qml" ? "dockCapsule" : "dockBar");
        tryVerify(() => capsule.width > capsule.height * 2);
        const dockCentre = capsule.mapToItem(desktop, capsule.width / 2, capsule.height / 2).y;
        const fabCentre = s.contentItem.y + s.height / 2;
        console.log("REPAIR_MEASURE " + JSON.stringify({ defect: "b", expanded: data.expanded, fab_centre: fabCentre,
            dock_centre: dockCentre, difference: fabCentre - dockCentre, right_margin: 1280 - s.contentItem.x - s.width }));
        verify(Math.abs(fabCentre - dockCentre) <= 1, "FAB aligned to actual Dock visual centre");
        compare(dock.edgeGeometry.centreInset, data.file === "DockPill.qml" ? dock.edgeGap + dock.pillThickness / 2 : 34);
        compare(800 - dockCentre, dock.edgeGeometry.centreInset);
        compare(dock.edgeGeometry.output, s.screen.name);
        const dockWindow = dock.children.find(item => item.contentItem !== undefined);
        compare(dockWindow.screen.name, dock.edgeGeometry.output);
        dock.screen = { name: "second-output", width: 1280, height: 800 };
        compare(dockWindow.screen.name, "second-output");
        compare(dock.edgeGeometry.output, "second-output");
        compare(s.bottomMargin, 32);
        dock.screen = s.screen;
        compare(s.bottomMargin, data.file === "DockPill.qml" ? 18 : 6);
        dock.release();
        compare(dock.edgeGeometry.visible, false);
        compare(s.bottomMargin, 32);
        compare(1280 - s.contentItem.x - s.width, 32);
    }
    function test_dock_alignment_scope_data() {
        const cases = [
            { tag: "default", file: "DockPill.qml", package: "ditto.dock.pill", margin: 18 },
            { tag: "replacement", file: "DockBottom.qml", package: "ditto.dock.bottom", margin: 6 },
            { tag: "hidden", file: "DockPill.qml", package: "ditto.dock.pill", hidden: true, margin: 32 },
            { tag: "left", file: "DockPill.qml", package: "ditto.dock.pill", position: "left", margin: 32 },
            { tag: "other-output", file: "DockPill.qml", package: "ditto.dock.pill", otherOutput: true, margin: 32 },
            { tag: "top-entry", file: "DockPill.qml", package: "ditto.dock.pill", corner: "top_right", margin: 32 },
            { tag: "scale-2", file: "DockPill.qml", package: "ditto.dock.pill", scale: 2, margin: 32 },
            { tag: "absent", margin: 32 }
        ];
        let rows = [];
        for (const row of cases) rows = rows.concat([false, true].map(label => Object.assign({}, row,
            { tag: row.tag + (label ? "-label" : "-circle"), label: label })));
        return rows;
    }
    function test_dock_alignment_scope(data) {
        const s = surface(); s.labelExpanded = data.label; s.entryScale = data.scale || 1;
        s.corner = data.corner || "bottom_right";
        let dock = null;
        if (data.file) {
            const c = Qt.createComponent(Qt.resolvedUrl("../.staged/providers/" + data.file));
            compare(c.status, Component.Ready, c.errorString());
            const incubator = c.incubateObject(testCase, { tokens: tokens, client: client,
                screen: data.otherOutput ? { name: "other-output" } : s.screen,
                config: { position: data.position || "bottom", pinned: Data.pinned }, shown: false });
            incubator.forceCompletion(); dock = incubator.object;
            verify(dock !== null, c.errorString()); mounted.push(dock);
            dock.shown = !data.hidden;
            s.dockMount = { binding: { package: data.package }, object: dock };
        }
        compare(s.margins.bottom, data.margin, "exact alignment or fixed 32 px fallback");
        if (data.corner) compare(s.contentItem.y, 64);
        else compare(s.contentItem.y + s.height, 800 - data.margin);
        verify(s.contentItem.x >= 0 && s.contentItem.x + s.width <= 1280);
        verify(s.contentItem.y >= 0 && s.contentItem.y + s.height <= 800);
        if (dock && dock.shown && !data.otherOutput) {
            const windows = layer.children.filter(item => item.objectName === "stubPanelWindow"
                && item !== s.contentItem && item.visible);
            verify(windows.length > 0);
            for (const w of windows) verify(s.contentItem.x + s.width <= w.x || s.contentItem.x >= w.x + w.width
                || s.contentItem.y + s.height <= w.y || s.contentItem.y >= w.y + w.height,
                "assistant and Dock window do not overlap in the fixture");
        }
        if (data.scale === 2) compare(800 - s.contentItem.y - s.height / 2, 88);
        // Read live visibility/edge changes, without remounting the assistant.
        if (data.tag.indexOf("default-") === 0) {
            dock.shown = false; compare(s.margins.bottom, 32);
            dock.shown = true; compare(s.margins.bottom, 18);
            dock.config = { position: "left", pinned: Data.pinned }; compare(s.margins.bottom, 32);
            dock.config = { position: "bottom", pinned: Data.pinned }; compare(s.margins.bottom, 18);
            s.dockMount = null; compare(s.margins.bottom, 32);
        }
        console.log("DOCK_SCOPE " + JSON.stringify({ scenario: data.tag, scale: s.entryScale,
            width: s.width, height: s.height, bottom_margin: s.margins.bottom }));
    }
    function test_neutral_geometry_data() {
        return [
            { tag: "third-provider", margin: 22 },
            { tag: "third-provider-label", label: true, margin: 22 },
            { tag: "bottom-left", corner: "bottom_left", margin: 22 },
            { tag: "no-property", object: {}, margin: 32 },
            { tag: "no-object", noObject: true, margin: 32 },
            { tag: "null", geometry: null, margin: 32 },
            { tag: "unknown-version", patch: { version: 2 }, margin: 32 },
            { tag: "string-version", patch: { version: "1" }, margin: 32 },
            { tag: "other-output", patch: { output: "other" }, margin: 32 },
            { tag: "missing-output", patch: { output: undefined }, margin: 32 },
            { tag: "empty-output", patch: { output: "" }, margin: 32 },
            { tag: "hidden", patch: { visible: false }, margin: 32 },
            { tag: "truthy-visible", patch: { visible: "true" }, margin: 32 },
            { tag: "top-dock", patch: { edge: "top" }, margin: 32 },
            { tag: "right-dock", patch: { edge: "right" }, margin: 32 },
            { tag: "missing-inset", patch: { centreInset: undefined }, margin: 32 },
            { tag: "string-inset", patch: { centreInset: "50" }, margin: 32 },
            { tag: "negative-inset", patch: { centreInset: -1 }, margin: 32 },
            { tag: "nan-inset", patch: { centreInset: NaN }, margin: 32 },
            { tag: "infinite-inset", patch: { centreInset: Infinity }, margin: 32 },
            { tag: "scaled-fits", scale: 1.5, margin: 8 },
            { tag: "scaled-too-large", scale: 2, margin: 32 },
            { tag: "exact-fit", patch: { centreInset: 28 }, margin: 0 },
            { tag: "legacy-theme", theme: "soft-jelly", margin: 32 },
            { tag: "capsule", style: "capsule", margin: 32 }
        ];
    }
    function test_neutral_geometry(data) {
        const s = surface();
        s.labelExpanded = data.label === true;
        s.corner = data.corner || "bottom_right";
        s.entryScale = data.scale || 1;
        s.entryStyle = data.style || "fab";
        if (data.theme) tokens.appearance = { theme: data.theme, tokens: {}, reduced_motion: true };
        const dock = createTemporaryObject(thirdDock, testCase);
        verify(dock !== null);
        if (data.geometry === null) dock.edgeGeometry = null;
        else dock.edgeGeometry = Object.assign({}, dock.edgeGeometry, data.patch || {});
        // Deliberately no binding/package or private Dock fields.
        s.dockMount = { object: data.noObject ? null : data.object || dock };
        compare(s.bottomMargin, data.margin);
        compare(s.margins.bottom, data.margin);
        if (data.corner) compare(s.contentItem.x, 32);
    }
    function test_neutral_geometry_live_changes() {
        const s = surface();
        const dock = createTemporaryObject(thirdDock, testCase);
        s.dockMount = { object: dock };
        compare(s.bottomMargin, 22);
        for (const patch of [{ visible: false }, { edge: "left" }, { output: "other" }, { version: 99 }]) {
            const previous = dock.edgeGeometry;
            dock.edgeGeometry = Object.assign({}, previous, patch);
            compare(s.bottomMargin, 32);
            dock.edgeGeometry = previous;
            compare(s.bottomMargin, 22);
        }
        dock.edgeGeometry = Object.assign({}, dock.edgeGeometry, { centreInset: 60 });
        compare(s.bottomMargin, 32);
        dock.edgeGeometry = Object.assign({}, dock.edgeGeometry, { centreInset: 64 });
        compare(s.bottomMargin, 36);
        s.screen = { name: "other", width: 1280, height: 800 };
        compare(s.bottomMargin, 32);
        s.screen = null;
        compare(s.bottomMargin, 32);
        s.screen = { name: "fixture", width: 1280, height: 800 };
        compare(s.bottomMargin, 36);
        s.dockMount = { object: {} };
        compare(s.bottomMargin, 32);
        s.dockMount = { object: dock };
        compare(s.bottomMargin, 36);
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
        // The light recipe draws an application style (#116, J1 by default):
        // its suggestions are tonal buttons in a wrapping row; the legacy
        // presentation's are subtle buttons. Either must keep the padding.
        const buttons = [];
        const walk = item => { for (const o of item.children) { if (o.kind !== undefined && o.visible) buttons.push(o); else walk(o); } };
        walk(examples);
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
