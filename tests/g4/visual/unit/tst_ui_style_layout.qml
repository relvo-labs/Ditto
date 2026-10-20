import QtQuick
import QtTest
import DittoStub
import Quickshell
import "../fixtures" as Fixtures

// #116 phase 2 (owner 2026-10-20: three selectable styles, J1 by default) on
// the real files of a staged tree (`tree`: "current" is the working copy;
// a RED run points it at an earlier commit staged the same way). Geometry
// is checked offscreen at the VM's 1600×900, from the defects found on the
// VM at c9df5eb: the settings title under the tasks panel, the last saved
// composition not reachable, the character over the chat tabs, an example
// under the composer, J3 tools over the tabs, 「新對話」 with AI off, J3's
// hollow window beads and grey text too faint. Fixture data, no Core, no
// compositor: development evidence only.
TestCase {
    id: testCase
    name: "UiStyleLayout"
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
    Fixtures.ConversationFixture { id: activeConversation; scene: "active" }
    property var created: []

    // StubDesktop is shared by every test file of the run.
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
    }
    function cleanup() {
        for (let i = created.length - 1; i >= 0; i--) {
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
    /// The style as the Profile holds it (no assignment to uiStyle).
    function tokensFor(style, extra) {
        const tokens = style === undefined ? {} : { ui_style: style };
        return make("shell/jelly/Tokens.qml", { appearance: Object.assign({ theme: "soft-jelly-light", tokens: tokens, locale: "zh-TW" }, extra || {}) }, "current");
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
    function named(root, name, role) {
        return all(root, item => shown(item) && item.Accessible.name === name && (role === undefined || item.Accessible.role === role));
    }
    function box(item, into) {
        return item.mapToItem(into || desktop, 0, 0, item.width, item.height);
    }
    function overlaps(a, b) {
        return a.x < b.x + b.width && b.x < a.x + a.width && a.y < b.y + b.height && b.y < a.y + a.height;
    }
    function contrast(a, b) {
        const linear = c => c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4);
        const luminance = c => 0.2126 * linear(c.r) + 0.7152 * linear(c.g) + 0.0722 * linear(c.b);
        const la = luminance(a), lb = luminance(b);
        return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05);
    }
    function styleRows() {
        return styles.map(style => ({ tag: style, style: style }));
    }

    // ---- settings window -------------------------------------------------------------
    // The tasks panel sits under the top bar at the top left (bottom at about
    // 82 px on the VM) and the pill Dock reserves about 82 px at the bottom.
    // Wherever Wayfire centres the window (work area or output), its title
    // row must be below 90 px and its bottom above the Dock.
    function test_settings_title_clears_the_top_panels_data() { return styleRows(); }
    function test_settings_title_clears_the_top_panels(row) {
        const centers = make("shell/centers/Centers.qml", { client: client, tokens: tokensFor(row.style), conversation: offConversation,
            page: "composition", screen: { width: 1600, height: 900 } });
        waitForRendering(desktop);
        const height = centers.implicitHeight;
        const workTop = 36 + (900 - 36 - 82 - height) / 2;
        const outputTop = (900 - height) / 2;
        verify(workTop >= 90 && outputTop >= 90, "a " + height + " px window would put its title under the tasks panel");
        verify(outputTop + height <= 900 - 96, "the bottom stays above the Dock");
        const title = named(centers, "Ditto 設定", Accessible.TitleBar)[0];
        verify(title, "one title row");
        const titleBox = box(title, centers);
        verify(titleBox.y >= 8 && titleBox.y + titleBox.height <= 52 + 1, "title inside its row: " + JSON.stringify(titleBox));
        verify(titleBox.x >= 0 && titleBox.x + titleBox.width <= centers.width);
    }

    function page(centers) {
        const flicks = all(centers, item => item.contentY !== undefined && item.flickableDirection !== undefined && shown(item));
        flicks.sort((a, b) => b.contentHeight - a.contentHeight);
        return flicks[0];
    }

    // Scrolled to the end, the last saved composition is whole.
    function test_last_saved_composition_scrolls_fully_into_view_data() { return styleRows(); }
    function test_last_saved_composition_scrolls_fully_into_view(row) {
        const centers = make("shell/centers/Centers.qml", { client: client, tokens: tokensFor(row.style), conversation: offConversation,
            page: "composition", screen: { width: 1600, height: 900 } });
        tryVerify(() => all(centers, item => item.Accessible.role === Accessible.Grouping && item.Accessible.name === "簡報").length > 0, 3000);
        waitForRendering(desktop);
        const flick = page(centers);
        verify(flick.contentHeight > flick.height, "the page overflows at 1600×900");
        const scrollBar = one(centers, "centersScrollBar");
        verify(scrollBar && shown(scrollBar), "a styled page shows that it scrolls");
        // Scrolled to the end, nothing drawn on the page is below the
        // visible part (the end of the page can be reached).
        flick.contentY = flick.contentHeight - flick.height;
        waitForRendering(desktop);
        let bottom = 0;
        for (const item of all(flick.contentItem, item => shown(item) && item.height > 0 && item.width > 0))
            bottom = Math.max(bottom, box(item, flick).y + box(item, flick).height);
        verify(bottom <= flick.height + 0.5, "content ends at " + bottom + ", visible " + flick.height);
        // The last saved composition can be shown whole.
        const last = all(centers, item => item.Accessible.role === Accessible.Grouping && item.Accessible.name === "簡報" && item.radius !== undefined)[0];
        flick.contentY = 0;
        flick.contentY = Math.min(flick.contentHeight - flick.height, last.mapToItem(flick.contentItem, 0, 0).y + last.height - flick.height + 16);
        waitForRendering(desktop);
        const lastBox = box(last, flick);
        verify(lastBox.y >= 0 && lastBox.y + lastBox.height <= flick.height, "last card " + JSON.stringify(lastBox) + " in " + flick.height);
        // Keyboard: Tab onto the last card's ⋯ from the top scrolls it in.
        flick.contentY = 0;
        const menu = all(last, item => item.Accessible.role === Accessible.ButtonMenu && shown(item))[0];
        menu.forceActiveFocus(Qt.TabFocusReason);
        tryVerify(() => { const b = box(menu, flick); return b.y >= 0 && b.y + b.height <= flick.height; }, 1000, "focused ⋯ scrolled into view");
        // PageUp returns to the top.
        for (let i = 0; i < 6; i++) keyClick(Qt.Key_PageUp);
        compare(flick.contentY, 0);
    }

    // J3 tells the sidebar from the page by an edge; window beads are seen.
    function test_j3_edges_and_beads_are_visible() {
        const tokens = tokensFor("j3");
        verify(contrast(tokens.uiBeadRim, tokens.withAlpha(tokens.uiCanvas, 1)) >= 3, "hollow bead rim ≥3:1");
        verify(contrast(tokens.uiInkMuted, tokens.withAlpha(tokens.uiCanvas, 1)) >= 4.5);
        verify(contrast(tokens.uiInkMuted, tokens.withAlpha(tokens.uiSidebar, 1)) >= 4.5);
        verify(contrast(tokens.uiInkDisabled, tokens.withAlpha(tokens.uiCanvas, 1)) >= 4.5, "disabled labels stay readable");
        const centers = make("shell/centers/Centers.qml", { client: client, tokens: tokens, conversation: offConversation,
            page: "composition", screen: { width: 1600, height: 900 } });
        waitForRendering(desktop);
        const faces = all(centers, item => item.objectName === "beadFace");
        compare(faces.length, 3);
        for (const face of faces) verify(Qt.colorEqual(face.edge, tokens.uiBeadRim) && face.edgeWidth >= 2, "J3 bead rim");
        verify(tokens.uiSidebar.a > 0, "J3 sidebar has a tint");
    }

    // ---- chat beside the character (the VM's compact panel) --------------------------
    function panel(style, conversation) {
        return make("shell/chat/ChatPanel.qml", { client: client, tokens: tokensFor(style), conversation: conversation || offConversation,
            screen: { width: 1600, height: 900 }, animations: false, entryRect: Qt.rect(1512, 826, 56, 56) });
    }

    function test_compact_ai_off_fits_between_tabs_and_composer_data() { return styleRows(); }
    function test_compact_ai_off_fits_between_tabs_and_composer(row) {
        const chat = panel(row.style);
        waitForRendering(desktop);
        wait(50);
        const state = one(desktop, "chatAiOffState");
        verify(state && state.active, "the AI-off empty state");
        const views = one(desktop, "chatViews");
        const tools = one(desktop, "chatTools");
        const art = one(desktop, "emptyStateArt");
        const composer = all(desktop, item => item.Accessible.role === Accessible.EditableText && shown(item));
        verify(art && views && tools);
        verify(!overlaps(box(art), box(views)) && !overlaps(box(art), box(tools)), "the character does not cover the tabs or tools");
        verify(box(art).y >= box(views).y + box(views).height, "the character is below the tabs");
        verify(!overlaps(box(views), box(tools)), "tabs and tools do not overlap: " + JSON.stringify([box(views), box(tools)]));
        const examples = all(desktop, item => item.objectName === "emptyStateExample" && shown(item));
        verify(examples.length >= 2, "two or three examples, got " + examples.length);
        const stateBox = box(state);
        for (const example of examples) {
            const b = box(example);
            verify(b.y >= stateBox.y && b.y + b.height <= stateBox.y + stateBox.height, "example inside the empty state: " + JSON.stringify(b));
            for (const field of composer) verify(!overlaps(b, box(field)), "example not under the composer");
        }
        // Every bubble of the decoration stays beside the character.
        const pool = one(desktop, "emptyStatePool");
        verify(pool.clip === true);
        // The whole empty state fits without scrolling at this size.
        const scroller = one(desktop, "emptyStateScroller");
        verify(scroller.contentHeight <= scroller.height + 0.5, "fits: " + scroller.contentHeight + " in " + scroller.height);
    }

    function test_new_conversation_only_with_ai_on_data() { return styleRows(); }
    function test_new_conversation_only_with_ai_on(row) {
        panel(row.style, offConversation);
        waitForRendering(desktop);
        compare(named(desktop, "新對話", Accessible.Button).length, 0, "AI off: nothing to start");
        cleanup();
        StubDesktop.layer = desktop;
        panel(row.style, activeConversation);
        waitForRendering(desktop);
        compare(named(desktop, "新對話", Accessible.Button).length, 1, "AI on: 新對話 is there");
        const views = one(desktop, "chatViews"), tools = one(desktop, "chatTools");
        verify(!overlaps(box(views), box(tools)), "with all tools: no overlap " + JSON.stringify([box(views), box(tools)]));
    }

    // ---- personalization: the style choice ------------------------------------------
    function picker(style, extra) {
        const tokens = tokensFor(style, extra);
        const centers = make("shell/centers/Centers.qml", { client: client, tokens: tokens, conversation: offConversation,
            page: "personalization", screen: { width: 1600, height: 900 } });
        tryVerify(() => one(centers, "uiStylePicker") !== null, 3000);
        waitForRendering(desktop);
        return { centers: centers, tokens: tokens, picker: one(centers, "uiStylePicker") };
    }

    function test_style_picker_lists_three_with_j1_default() {
        const scene = picker(undefined);
        const cards = ["j1", "j2", "j3"].map(value => one(scene.picker, "styleCard_" + value));
        for (const card of cards) {
            verify(card && shown(card));
            compare(card.Accessible.role, Accessible.RadioButton);
            verify(card.Accessible.description.length > 0, "a one-line description");
        }
        compare(cards.map(card => card.Accessible.name), ["J1 果凍玻璃（預設）", "J2 軟糖", "J3 泡泡"]);
        compare(cards.map(card => card.Accessible.checked), [true, false, false], "no value: J1 is chosen");
        compare(scene.picker.Accessible.role, Accessible.Grouping);
        compare(scene.picker.Accessible.name, "外觀風格");
        verify(shown(one(cards[0], "styleMarker")) && !shown(one(cards[1], "styleMarker")), "a marker, not a ✓");
        for (const card of cards) verify(one(card, "stylePreview").width > 100, "a preview");
    }

    function test_style_picker_keyboard_moves_then_chooses() {
        const scene = picker("j1");
        const cards = ["j1", "j2", "j3"].map(value => one(scene.picker, "styleCard_" + value));
        compare(cards.map(card => card.activeFocusOnTab), [true, false, false], "one Tab stop: the chosen card");
        cards[0].forceActiveFocus(Qt.TabFocusReason);
        keyClick(Qt.Key_Right);
        verify(cards[1].activeFocus, "Right moves focus");
        compare(client.calls.length, 0, "moving focus does not choose");
        keyClick(Qt.Key_End);
        verify(cards[2].activeFocus);
        keyClick(Qt.Key_Right);
        verify(cards[0].activeFocus, "wraps");
        keyClick(Qt.Key_Left);
        verify(cards[2].activeFocus);
        keyClick(Qt.Key_Space);
        compare(JSON.stringify(client.calls), JSON.stringify([{ appearance: { tokens: { ui_style: "j3" } } }]), "Space chooses through setAppearance");
        client.calls = [];
        keyClick(Qt.Key_Home);
        verify(cards[0].activeFocus);
        keyClick(Qt.Key_Return);
        compare(client.calls.length, 0, "choosing the style in use is not a change");
        keyClick(Qt.Key_Right);
        keyClick(Qt.Key_Enter);
        compare(JSON.stringify(client.calls), JSON.stringify([{ appearance: { tokens: { ui_style: "j2" } } }]));
        client.calls = [];
        mouseClick(cards[2]);
        compare(JSON.stringify(client.calls), JSON.stringify([{ appearance: { tokens: { ui_style: "j3" } } }]), "pointer: same path");
    }

    function test_style_picker_previews_follow_reduced_transparency_and_low_power() {
        for (const extra of [{ reduced_transparency: true }, { low_power_style: true }, { reduced_motion: true }]) {
            const scene = picker("j3", extra);
            // The page shows Core's value (the fixture has none: J1); the
            // J3 card's preview is drawn by J3's own tokens either way.
            const card = one(scene.picker, "styleCard_j3");
            // The preview's tokens are its own (J3) with the person's settings.
            const surfaces = all(one(card, "stylePreview"), item => item.gloss !== undefined);
            verify(surfaces.length > 0);
            for (const surface of surfaces) {
                if (extra.reduced_transparency || extra.low_power_style) verify(!surface.gloss, JSON.stringify(extra) + ": no gloss in the preview");
            }
            cleanup();
            StubDesktop.layer = desktop;
        }
    }

    function test_style_picker_only_with_the_light_theme() {
        const tokens = make("shell/jelly/Tokens.qml", { appearance: { theme: "soft-jelly", tokens: { ui_style: "j2" }, locale: "zh-TW" } }, "current");
        const centers = make("shell/centers/Centers.qml", { client: client, tokens: tokens, conversation: offConversation, page: "personalization" });
        waitForRendering(desktop);
        const found = one(centers, "uiStylePicker");
        verify(!found || !shown(found), "the dark theme has no styles to choose");
    }

    // A committed change (Core's projection) restyles open windows at once.
    function test_open_windows_follow_a_committed_style() {
        const tokens = tokensFor(undefined);
        const centers = make("shell/centers/Centers.qml", { client: client, tokens: tokens, conversation: offConversation,
            page: "composition", screen: { width: 1600, height: 900 } });
        waitForRendering(desktop);
        const frame = () => one(centers, "centersFrame");
        compare(frame().radius, tokens.uiRadiusWindow);
        const j1Radius = frame().radius;
        tokens.appearance = { theme: "soft-jelly-light", tokens: { ui_style: "j2" }, locale: "zh-TW" };
        waitForRendering(desktop);
        verify(tokens.uiJ2);
        verify(frame().radius !== j1Radius, "J2 window corners");
        verify(all(centers, item => item.objectName === "jellyLip" && shown(item)).length > 0, "J2 lips appear");
        tokens.appearance = { theme: "soft-jelly-light", tokens: { ui_style: "j3" }, locale: "zh-TW" };
        waitForRendering(desktop);
        const faces = all(centers, item => item.objectName === "beadFace");
        for (const face of faces) verify(Qt.colorEqual(face.edge, tokens.uiBeadRim), "J3 beads now");
    }
}
