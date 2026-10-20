import QtQuick
import QtTest
import DittoStub
import Quickshell
import "../fixtures" as Fixtures

// #116 repair round 1 (review1 R1–R3, VM shots at b0dc73b), on the real
// files of a staged tree (`tree`: "current" is the working copy; the RED run
// points it at b0dc73b staged the same way). Tokens always come from the
// current tree. Fixture data, offscreen, Quickshell stubbed: development
// evidence. Real window flags on Wayfire are the coordinator's VM check.
//
// Offscreen text is about 4% narrower than on the VM (the empty state's
// message fits one 332 px line here, 320.9 px, and wraps on the VM); the
// chat cases also run at font_scale 1.05, whose 15 px text wraps the same
// way, so the VM's layout is reproduced here.
TestCase {
    id: testCase
    name: "UiStyleRepair1"
    width: 1600
    height: 900
    visible: true
    when: windowShown

    property string tree: "current"
    readonly property url staged: Qt.resolvedUrl("../.staged/ui116/")
    readonly property var styles: ["j1", "j2", "j3"]

    Item { id: desktop; width: 1600; height: 900 }
    Fixtures.AppFixtureClient { id: client }
    Fixtures.ConversationFixture { id: offConversation; scene: "off" }
    property var created: []

    function cleanupTestCase() {
        StubDesktop.screenWidth = 1280;
        StubDesktop.screenHeight = 800;
    }
    function init() {
        StubDesktop.layer = desktop;
        StubDesktop.screenWidth = 1600;
        StubDesktop.screenHeight = 900;
        Quickshell.environment = ({});
        client.calls = [];
        client.reads = [];
        client.appearanceTokens = { accent: "#b9a4ff" };
    }
    function cleanup() {
        for (let i = created.length - 1; i >= 0; i--) {
            if (!created[i] || typeof created[i].destroy !== "function") continue;   // destroyed by the test
            if (created[i].release) created[i].release();
            created[i].destroy();
        }
        created = [];
        wait(0);
    }
    function make(path, properties, fromTree) {
        const component = Qt.createComponent(staged + (fromTree || tree) + "/" + path);
        verify(component.status === Component.Ready, component.errorString());
        const object = component.createObject(desktop, properties || {});
        verify(object !== null, path);
        created.push(object);
        return object;
    }
    function light(extraTokens, extra) {
        return Object.assign({ theme: "soft-jelly-light", tokens: Object.assign({ accent: "#b9a4ff" }, extraTokens || {}), locale: "zh-TW" }, extra || {});
    }
    function tokensWith(appearance) {
        return make("shell/jelly/Tokens.qml", { appearance: appearance }, "current");
    }
    function all(root, test) {
        const found = [];
        const walk = item => {
            for (const child of item.children) {
                if (test(child)) found.push(child);
                walk(child);
            }
        };
        walk(root);
        return found;
    }
    function one(root, name) {
        const found = all(root, item => item.objectName === name);
        return found.length > 0 ? found[0] : null;
    }
    function shown(item) {
        for (let node = item; node; node = node.parent) {
            if (!node.visible || node.opacity === 0) return false;
        }
        return true;
    }
    function box(item, into) {
        return item.mapToItem(into || desktop, 0, 0, item.width, item.height);
    }
    function overlaps(a, b) {
        return a.x < b.x + b.width && b.x < a.x + a.width && a.y < b.y + b.height && b.y < a.y + a.height;
    }
    function inside(inner, outer) {
        return inner.y >= outer.y - 0.5 && inner.y + inner.height <= outer.y + outer.height + 0.5;
    }

    // ---- Class A: the page shows and judges by the committed appearance ---------
    function personalization(tokens) {
        const centers = make("shell/centers/Centers.qml", { client: client, tokens: tokens, conversation: offConversation,
            page: "personalization", screen: { width: 1600, height: 900 } });
        tryVerify(() => one(centers, "uiStylePicker") !== null, 3000);
        waitForRendering(desktop);
        return centers;
    }
    function checkedStyles(centers) {
        return ["j1", "j2", "j3"].filter(value => one(centers, "styleCard_" + value).Accessible.checked);
    }

    // The page read J1; a change to J2 was committed elsewhere and its
    // profile_changed was missed. Core's projection (the Shell runs it) says
    // J2: the page shows J2, and choosing J1 is sent, not skipped.
    function test_style_choice_follows_the_committed_projection() {
        const tokens = tokensWith(light());
        const centers = personalization(tokens);
        compare(checkedStyles(centers), ["j1"]);
        client.appearanceTokens = { accent: "#b9a4ff", ui_style: "j2" };
        tokens.appearance = light({ ui_style: "j2" });   // no profileChanged
        waitForRendering(desktop);
        compare(checkedStyles(centers), ["j2"], "the committed J2, not the page's old read");
        client.capabilitiesReloaded();                   // resync / reconnect
        waitForRendering(desktop);
        compare(checkedStyles(centers), ["j2"]);
        mouseClick(one(centers, "styleCard_j1"));
        compare(JSON.stringify(client.calls), JSON.stringify([{ appearance: { tokens: { ui_style: "j1" } } }]),
                "back to J1 is a change, not skipped as 'already chosen'");
        client.calls = [];
        mouseClick(one(centers, "styleCard_j2"));
        compare(client.calls.length, 0, "choosing the committed value is not a change");
    }

    // Accent, corner roundness, text size, the three toggles and the
    // language follow a change made elsewhere (dittoctl, the Agent, undo).
    function test_appearance_controls_follow_an_external_change() {
        const tokens = tokensWith(light());
        const centers = personalization(tokens);
        const swatch = color => all(centers, item => item.Accessible.role === Accessible.RadioButton
            && item.Accessible.name === "強調色 " + color)[0];
        verify(swatch("#b9a4ff").Accessible.checked);
        const changed = { accent: "#8ab4ff", radius_scale: "1.5", font_scale: "1.15" };
        client.appearanceTokens = changed;
        tokens.appearance = light(changed, { reduced_transparency: true, low_power_style: true, reduced_motion: true, locale: "en" });
        client.capabilitiesReloaded();
        waitForRendering(desktop);
        verify(swatch("#8ab4ff").Accessible.checked && !swatch("#b9a4ff").Accessible.checked, "accent");
        const choice = name => all(centers, item => item.accessibleName === name && item.value !== undefined)[0];
        compare(choice("圓角").value, "1.5");
        compare(choice("文字大小").value, "1.15");
        compare(choice("語言").value, "en");
        for (const name of ["降低透明度", "低效能樣式（關閉模糊與陰影）", "減少動畫"]) {
            const toggle = all(centers, item => item.text === name && item.checked !== undefined)[0];
            verify(toggle && toggle.checked, name + " shows the committed value");
        }
    }

    // Composition and history re-read on a resync or reconnect, as plugins
    // and generated artifacts already do.
    function test_composition_and_history_reload_after_resync_data() {
        return [{ tag: "composition", page: "composition", read: "desktop.profiles.list" },
                { tag: "history", page: "history", read: "desktop.changes.list" },
                { tag: "personalization", page: "personalization", read: "desktop.appearance.get" }];
    }
    function test_composition_and_history_reload_after_resync(row) {
        const centers = make("shell/centers/Centers.qml", { client: client, tokens: tokensWith(light()), conversation: offConversation,
            page: row.page, screen: { width: 1600, height: 900 } });
        waitForRendering(desktop);
        verify(client.reads.indexOf(row.read) >= 0);
        client.reads = [];
        client.capabilitiesReloaded();
        verify(client.reads.indexOf(row.read) >= 0, row.page + " re-reads " + row.read + " after a resync: " + JSON.stringify(client.reads));
    }

    // ---- Class B: the header undoes only what it did --------------------------
    Component {
        id: headerHarness
        Window {
            id: harness
            property var tokens
            property bool styled: tokens.uiCandidate === true
            readonly property QtObject host: QtObject {
                property bool maximized: false
                property bool minimized: false
                function startSystemMove() {}
            }
            width: 400; height: 200
            visible: true
            Loader {
                id: headerLoader
                objectName: "harnessHeader"
                anchors.left: parent.left
                anchors.right: parent.right
                active: harness.styled
                // As Centers/ChatWindow do: the host is bound at creation.
                Component.onCompleted: setSource(testCase.staged + testCase.tree + "/shell/ui/WindowHeader.qml",
                    { tokens: harness.tokens, hostWindow: harness.host, title: "fixture" })
            }
        }
    }
    function test_frameless_is_undone_when_the_style_goes_away_data() {
        return [{ tag: "light-dark-light", leave: { theme: "soft-jelly", tokens: {} } },
                { tag: "undo-to-no-theme", leave: { tokens: {} } }];
    }
    function test_frameless_is_undone_when_the_style_goes_away(row) {
        const tokens = tokensWith({ theme: "soft-jelly", tokens: {} });
        const original = Qt.Window | Qt.WindowStaysOnTopHint;
        const win = headerHarness.createObject(testCase, { tokens: tokens, flags: original });
        created.push(win);
        verify(!(win.flags & Qt.FramelessWindowHint));
        tokens.appearance = light();
        tryVerify(() => (win.flags & Qt.FramelessWindowHint) !== 0, 1000, "styled: one title, Qt draws none");
        verify(win.flags & Qt.WindowStaysOnTopHint);
        tokens.appearance = row.leave;
        tryCompare(win, "flags", original, 1000, "no style: the native title bar is back, other flags kept");
        tokens.appearance = light({ ui_style: "j3" });
        tryVerify(() => (win.flags & Qt.FramelessWindowHint) !== 0, 1000, "styled again");
        tokens.appearance = row.leave;
        tryCompare(win, "flags", original, 1000);
    }
    function test_frameless_set_by_someone_else_is_kept() {
        const tokens = tokensWith(light());
        const original = Qt.Window | Qt.FramelessWindowHint;
        const win = headerHarness.createObject(testCase, { tokens: tokens, flags: original });
        created.push(win);
        tryVerify(() => one(win.contentItem, "harnessHeader").status === Loader.Ready, 1000);
        tokens.appearance = { theme: "soft-jelly", tokens: {} };
        tryVerify(() => one(win.contentItem, "harnessHeader").status === Loader.Null, 1000);
        compare(win.flags, original, "the header did not add it, so it does not take it away");
    }

    // ---- Class C/D: the compact chat beside the character, AI off -------------
    function panel(style, fontScale) {
        const tokens = tokensWith(light({ ui_style: style, font_scale: String(fontScale) }));
        const chat = make("shell/chat/ChatPanel.qml", { client: client, tokens: tokens, conversation: offConversation,
            screen: { width: 1600, height: 900 }, animations: false, entryRect: Qt.rect(1512, 826, 56, 56) });
        waitForRendering(desktop);
        wait(50);
        return { tokens: tokens, chat: chat };
    }
    function composerBox() {
        const fields = all(desktop, item => item.Accessible.role === Accessible.EditableText && shown(item));
        verify(fields.length > 0);
        return box(fields[0]);
    }

    // D: at the default text size, on the VM's metrics, nothing of the empty
    // state is under the composer: it fits without scrolling.
    function test_compact_ai_off_fits_at_vm_metrics_data() {
        const rows = [];
        for (const style of styles) for (const scale of [1, 1.05]) rows.push({ tag: style + "@" + scale, style: style, scale: scale });
        return rows;
    }
    function test_compact_ai_off_fits_at_vm_metrics(row) {
        panel(row.style, row.scale);
        const scroller = one(desktop, "emptyStateScroller");
        const column = one(desktop, "emptyStateColumn");
        verify(column.height <= scroller.height + 0.5, "fits: " + column.height + " in " + scroller.height);
        const visibleBox = box(scroller);
        const examples = all(desktop, item => item.objectName === "emptyStateExample" && shown(item));
        verify(examples.length >= 2, "two or three examples");
        for (const example of examples) {
            verify(inside(box(example), visibleBox), "example whole: " + JSON.stringify(box(example)) + " in " + JSON.stringify(visibleBox));
            verify(!overlaps(box(example), composerBox()), "not under the composer");
        }
    }

    // C: very large text does not fit; every part is still reached by Tab
    // (the examples are readable stops, not buttons) and shown whole, and the
    // keyboard pages the rest.
    function test_compact_large_text_reaches_every_part_by_keyboard_data() {
        return styles.map(style => ({ tag: style, style: style }));
    }
    function test_compact_large_text_reaches_every_part_by_keyboard(row) {
        panel(row.style, 2);
        const scroller = one(desktop, "emptyStateScroller");
        const state = one(desktop, "chatAiOffState");
        verify(one(desktop, "emptyStateColumn").height > scroller.height, "this case overflows");
        const primary = all(state, item => item.Accessible.name === "開啟 AI 對話" && item.activeFocusOnTab)[0];
        scroller.contentY = scroller.contentHeight - scroller.height;   // start scrolled away
        primary.forceActiveFocus(Qt.TabFocusReason);
        const view = box(scroller);
        tryVerify(() => inside(box(primary), view), 1000, "the focused action is scrolled into view");
        const examples = all(state, item => item.objectName === "emptyStateExample");
        const reached = [];
        for (let step = 0; step < 8; step++) {
            keyClick(Qt.Key_Tab);
            const focused = desktop.Window.activeFocusItem;
            let within = false;
            for (let node = focused; node; node = node.parent) if (node === state) within = true;
            if (!within) break;
            tryVerify(() => inside(box(focused), view), 1000, "focused part whole: " + focused.Accessible.name);
            if (examples.indexOf(focused) >= 0) reached.push(examples.indexOf(focused));
        }
        compare(reached[reached.length - 1], examples.length - 1, "Tab reaches the last example");
        // The keyboard also pages: back to the top with PageUp.
        primary.forceActiveFocus(Qt.TabFocusReason);
        for (let i = 0; i < 6; i++) keyClick(Qt.Key_PageUp);
        compare(scroller.contentY, 0);
        keyClick(Qt.Key_PageDown);
        verify(scroller.contentY > 0, "PageDown scrolls");
    }

    // D: the chat surfaces do not show readable shapes of what is behind
    // (Wayfire 0.11 has no background blur); reduced transparency is opaque.
    function test_chat_surfaces_hide_what_is_behind_data() {
        const rows = [];
        for (const style of styles) for (const mode of ["normal", "reduced-transparency"]) rows.push({ tag: style + "/" + mode, style: style, mode: mode });
        return rows;
    }
    function test_chat_surfaces_hide_what_is_behind(row) {
        const extra = row.mode === "reduced-transparency" ? { reduced_transparency: true } : {};
        const tokens = tokensWith(light({ ui_style: row.style }, extra));
        const minimum = row.mode === "normal" ? 0.985 : 1;
        const chatPanel = make("shell/chat/ChatPanel.qml", { client: client, tokens: tokens, conversation: offConversation,
            screen: { width: 1600, height: 900 }, animations: false, entryRect: Qt.rect(1512, 826, 56, 56) });
        const frame = one(desktop, "chatPresentationFrame");
        verify(frame.color.a >= minimum, "compact panel " + frame.color.a);
        chatPanel.destroy();
        wait(0);
        const window = make("shell/chat/ChatWindow.qml", { client: client, tokens: tokens, conversation: offConversation,
            assistantPresentation: true, screen: { width: 1600, height: 900 } });
        const fills = all(window, item => item.objectName === "jellyFill");
        verify(fills.length > 0);
        verify(fills[0].color.a >= minimum, "chat window " + fills[0].color.a);
        const approval = make("shell/chat/ApprovalWindow.qml", { client: client, tokens: tokens,
            approval: { request_id: "req", request: { capability_id: "desktop.windows.list", resource: "desktop.windows.read", purpose: "fixture" } } });
        const approvalFill = all(approval, item => item.objectName === "jellyFill")[0];
        verify(approvalFill.color.a >= minimum, "approval " + approvalFill.color.a);
    }
}
