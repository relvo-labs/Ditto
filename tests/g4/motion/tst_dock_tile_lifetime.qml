import QtQuick
import QtTest
import DittoStub
import "../../../shell/jelly" as Jelly

// Real provider delegates and input events; Core and layer-shell are fixtures.
TestCase {
    id: testCase
    name: "DockTileLifetime"
    width: 1280; height: 800
    visible: true
    when: windowShown
    Item { id: layer; width: 1280; height: 800 }
    MouseArea { id: outside; width: 40; height: 40; hoverEnabled: true }
    Jelly.Tokens { id: tokens }
    QtObject {
        id: client
        property var windows: []
        property var calls: []
        property bool online: true
        property string status: ""
        function t(text) { return text; }
        function focusWindow(id) { calls = calls.concat([id]); }
        function closeWindow(id) { calls = calls.concat(["close " + id]); }
        function capabilityAvailable(id) { return true; }
        function capability(method, args, ok, fail) {
            ok({ apps: ["fixture", "other", "third"].map(id => ({ app_id: id, name: id, icon: "" })) });
        }
    }
    property var provider: null
    property var feedbackAnimation: null
    SignalSpy { id: feedbackStarts; target: feedbackAnimation; signalName: "started" }
    function mount(kind, theme) {
        StubDesktop.layer = layer;
        tokens.appearance = { theme: theme || "soft-jelly-light" };
        client.windows = [
            { id: "A", app_id: "fixture", title: "A", focused: true, x: 0, y: 0, width: 640, height: 480 },
            { id: "B", app_id: "other", title: "B", focused: false },
            { id: "C", app_id: "third", title: "C", focused: false }];
        client.calls = [];
        const component = Qt.createComponent(Qt.resolvedUrl("../visual/.staged/providers/Dock" + (kind || "Pill") + ".qml"));
        compare(component.status, Component.Ready, component.errorString());
        const incubator = component.incubateObject(testCase, { client: client, tokens: tokens,
            config: { pinned: ["fixture", "other", "third"] }, shown: false });
        incubator.forceCompletion();
        provider = incubator.object;
        verify(!!provider);
        provider.shown = true;
        wait(220);
        outside.forceActiveFocus();
        mouseMove(outside, 10, 10);
    }
    function cleanup() {
        mouseRelease(outside, 10, 10);
        if (provider) { provider.release(); provider.destroy(); }
        provider = null;
        feedbackAnimation = null;
        wait(10);
    }
    function tiles() {
        const found = [];
        function visit(item) {
            for (const child of item.children || []) {
                if (child.modelData !== undefined && child.activeFocusOnTab) found.push(child);
                visit(child);
            }
        }
        visit(layer);
        return found;
    }
    function tile(id) {
        return tiles().find(item => (item.modelData.window ? item.modelData.window.id : item.modelData.id) === id) || null;
    }
    function area(item) {
        return item.children.find(child => child.pressed !== undefined && child.acceptedButtons !== undefined);
    }
    function mutate(kind) {
        if (kind === "title") client.windows = client.windows.map(w => Object.assign({}, w, { title: w.title + " changed" }));
        if (kind === "geometry") client.windows = client.windows.map(w => Object.assign({}, w, { x: 10, y: 20, width: 900, height: 700 }));
        if (kind === "open") client.windows = client.windows.concat([{ id: "Z", app_id: "new", title: "Z", focused: false }]);
        if (kind === "close") client.windows = client.windows.filter(w => w.id !== "C");
        if (kind === "apps-reload") { provider.appsLoaded = false; provider.loadApps(); }
        if (kind === "apps-reorder") provider.apps = provider.apps.slice().reverse();
        if (kind === "pinned-reorder") provider.config = { pinned: ["fixture", "third", "other"] };
        if (kind === "windows-reorder") client.windows = [client.windows[0], client.windows[2], client.windows[1]];
        if (kind === "focus") client.windows = client.windows.map(w => Object.assign({}, w, { focused: w.id === "B" }));
    }
    function test_upsert_preserves_input_data() {
        const rows = [];
        for (const state of ["hover", "press", "focus"])
            for (const change of ["title", "geometry", "open", "close", "apps-reload", "apps-reorder", "pinned-reorder", "focus"])
                rows.push({ tag: state + "-" + change, state: state, change: change });
        return rows;
    }
    function test_upsert_preserves_input(data) {
        mount();
        const original = tile("A");
        if (data.state === "hover") { mouseMove(original, 26, 26); verify(area(original).containsMouse); }
        if (data.state === "press") { mousePress(original, 26, 26); verify(area(original).pressed); }
        if (data.state === "focus") { original.forceActiveFocus(); verify(original.activeFocus); }
        mutate(data.change);
        const current = tile("A");
        // Check behavior first: a recreated delegate exists but loses input.
        if (data.state === "hover") verify(area(current).containsMouse, "hover survives " + data.change);
        if (data.state === "press") verify(area(current).pressed, "press survives " + data.change);
        if (data.state === "focus") verify(current.activeFocus, "keyboard focus survives " + data.change);
        compare(current, original, "same identity keeps its delegate");
        if (data.change === "title") compare(current.modelData.window.title, "A changed");
        if (data.change === "geometry") compare(current.modelData.window.width, 900);
        if (data.change === "focus") { compare(current.current, false); compare(tile("B").current, true); }
        if (data.state === "press") { mouseRelease(current, 26, 26); compare(client.calls, ["A"]); }
        if (data.state === "focus") { keyClick(Qt.Key_Return); compare(client.calls, ["A"]); }
    }
    function test_feedback_stream_continues_without_restart_data() {
        return ["hover", "press", "focus"].map(state => ({ tag: state, state: state }));
    }
    function test_feedback_stream_continues_without_restart(data) {
        mount();
        const original = tile("A");
        feedbackAnimation = original.data.find(item => item.property === "feedbackScale");
        verify(!!feedbackAnimation);
        feedbackStarts.clear();
        if (data.state === "hover") mouseMove(original, 26, 26);
        if (data.state === "press") mousePress(original, 26, 26);
        if (data.state === "focus") original.forceActiveFocus();
        wait(25);
        const target = data.state === "press" ? 0.90 : 0.96;
        verify(original.feedbackScale < 1 && original.feedbackScale > target);
        compare(feedbackStarts.count, 1);
        for (const change of ["title", "apps-reload", "apps-reorder", "pinned-reorder", "focus"]) {
            const before = original.feedbackScale;
            mutate(change);
            compare(tile("A"), original);
            compare(original.feedbackScale, before, change + " keeps the in-flight value");
            compare(feedbackStarts.count, 1, change + " does not restart feedback");
        }
        for (let i = 0; i < 20; ++i) {
            const before = original.feedbackScale;
            client.windows = client.windows.map(w => Object.assign({}, w, { x: i, width: 800 + i }));
            compare(tile("A"), original);
            compare(original.feedbackScale, before, "upsert does not reset interpolation");
            compare(feedbackStarts.count, 1, "no restart under geometry stream");
            wait(5);
            verify(original.feedbackScale <= before);
        }
        tryCompare(feedbackAnimation, "running", false);
        compare(original.feedbackScale, target);
    }
    function test_bottom_preserves_input_data() {
        const rows = [];
        for (const state of ["press", "focus"])
            for (const change of ["title", "geometry", "open", "close", "windows-reorder", "focus"])
                rows.push({ tag: state + "-" + change, state: state, change: change });
        return rows;
    }
    function test_bottom_preserves_input(data) {
        mount("Bottom");
        const original = tile("A");
        if (data.state === "press") { mousePress(original, 70, 17); verify(area(original).pressed); }
        if (data.state === "focus") original.forceActiveFocus();
        mutate(data.change);
        compare(tile("A"), original);
        if (data.state === "press") {
            verify(area(original).pressed);
            mouseRelease(original, 70, 17);
            compare(client.calls, ["A"]);
        } else {
            verify(original.activeFocus);
            keyClick(Qt.Key_Space);
            compare(client.calls, ["A"]);
        }
        if (data.change === "title") compare(original.Accessible.name, "A changed（作用中）");
        if (data.change === "geometry") compare(original.modelData.width, 900);
        if (data.change === "focus") compare(original.Accessible.name, "A");
    }
    function test_move_keeps_delegate_and_keyboard_order_data() {
        return ["Pill", "Bottom"].map(kind => ({ tag: kind, kind: kind }));
    }
    function test_move_keeps_delegate_and_keyboard_order(data) {
        mount(data.kind);
        const a = tile("A"), b = tile("B"), c = tile("C");
        a.forceActiveFocus();
        if (data.kind === "Pill") provider.config = { pinned: ["third", "fixture", "other"] };
        else client.windows = [client.windows[2], client.windows[0], client.windows[1]];
        wait(0);
        compare(tile("A"), a); compare(tile("B"), b); compare(tile("C"), c);
        verify(a.activeFocus);
        tryVerify(() => c.x < a.x && a.x < b.x, 1000, "real layout follows reordered model");
        keyClick(Qt.Key_Tab);
        verify(b.activeFocus, "tab order follows moved delegates");
        keyClick(Qt.Key_Return);
        compare(client.calls, ["B"]);
    }
    function test_pinned_identity_survives_window_replacement() {
        mount();
        const original = tile("A");
        original.forceActiveFocus();
        client.windows = client.windows.filter(w => w.id !== "A");
        compare(findChild(layer, "dockTile_fixture"), original);
        compare(original.running, false);
        verify(original.activeFocus);
        client.windows = client.windows.concat([{ id: "A2", app_id: "fixture", title: "new", focused: true }]);
        compare(tile("A2"), original);
        verify(original.activeFocus);
        keyClick(Qt.Key_Return);
        compare(client.calls, ["A2"], "activation uses the latest window, not the old payload");
    }
    function test_removed_identity_retires_input_data() {
        const rows = [];
        for (const kind of ["Pill", "Bottom"])
            for (const state of ["press", "focus"])
                rows.push({ tag: kind + "-" + state, kind: kind, state: state });
        return rows;
    }
    function test_removed_identity_retires_input(data) {
        mount(data.kind);
        if (data.kind === "Pill") {
            provider.config = { pinned: [] };
            tryVerify(() => tile("A").x < tile("B").x && tile("B").x < tile("C").x);
        }
        const original = tile("A");
        const point = original.mapToItem(layer, 20, 17);
        if (data.state === "press") { mousePress(original, 20, 17); verify(area(original).pressed); }
        else original.forceActiveFocus();
        client.windows = client.windows.filter(w => w.id !== "A");
        wait(0);
        compare(tile("A"), null);
        compare(tiles().length, 2, "removed delegate leaves no visual item");
        verify(tiles().every(item => !item.activeFocus), "focus is not transferred to an unrelated tile");
        mouseRelease(layer, point.x, point.y);
        compare(client.calls, [], "removed press must not activate a neighbor");
        client.windows = client.windows.concat([{ id: "A", app_id: "fixture", title: "reborn", focused: false }]);
        verify(!tile("A").activeFocus);
        verify(!area(tile("A")).pressed);
    }
    function test_release_and_replacement_data() {
        return ["Pill", "Bottom"].map(kind => ({ tag: kind, kind: kind }));
    }
    function test_release_and_replacement(data) {
        mount(data.kind);
        const original = tile("A");
        original.forceActiveFocus();
        mousePress(original, 20, 17);
        wait(25);
        provider.release();
        const panel = provider.data.find(item => item.exclusiveZone !== undefined);
        compare(panel.visible, false);
        compare(panel.exclusiveZone, 0);
        verify(!original.visible);
        if (data.kind === "Pill") {
            compare(original.motionRunning, false);
            compare(original.feedbackScale, 1);
        }
        provider.destroy(); provider = null;
        wait(10);
        compare(tiles().length, 0);
        mount(data.kind === "Pill" ? "Bottom" : "Pill");
        verify(!tile("A").activeFocus);
        verify(!area(tile("A")).pressed);
        mouseClick(tile("A"), 20, 17);
        compare(client.calls, ["A"], "replacement has one activation path");
    }
    function test_legacy_keeps_static_style_and_input() {
        mount("Pill", "soft-jelly");
        const original = tile("A");
        original.forceActiveFocus();
        const bubble = findChild(original, "dockLegacyBubble");
        const color = bubble.color;
        mutate("title");
        compare(tile("A"), original);
        verify(original.activeFocus);
        compare(bubble.visible, true);
        compare(bubble.color, color);
        compare(original.motionRunning, false);
        compare(original.width, 40);
    }
    function test_move_pressed_tile_data() {
        return ["Pill", "Bottom"].map(kind => ({ tag: kind, kind: kind }));
    }
    function test_move_pressed_tile(data) {
        mount(data.kind);
        const original = tile("A");
        mousePress(original, 20, 17);
        verify(area(original).pressed);
        const previousX = original.x;
        if (data.kind === "Pill") provider.config = { pinned: ["third", "fixture", "other"] };
        else client.windows = [client.windows[2], client.windows[0], client.windows[1]];
        tryVerify(() => original.x !== previousX);
        compare(tile("A"), original);
        verify(area(original).pressed, "moving an existing delegate keeps the pointer grab");
        mouseRelease(original, 20, 17);
        compare(client.calls, ["A"]);
    }
    function test_unpinned_window_ids_do_not_collapse_same_app() {
        mount();
        provider.config = { pinned: [] };
        client.windows = [
            { id: "A", app_id: "fixture", title: "one", focused: true },
            { id: "A2", app_id: "fixture", title: "two", focused: false }];
        tryVerify(() => tile("A").x < tile("A2").x);
        const first = tile("A"), second = tile("A2");
        second.forceActiveFocus();
        client.windows = [Object.assign({}, client.windows[1], { title: "new two", focused: true }),
            Object.assign({}, client.windows[0], { focused: false })];
        compare(tile("A"), first); compare(tile("A2"), second);
        verify(second.activeFocus);
        compare(second.modelData.window.title, "new two");
        compare(second.current, true); compare(first.current, false);
        keyClick(Qt.Key_Return);
        compare(client.calls, ["A2"]);
    }

    function test_duplicate_pinned_count_reduction_removes_only_retired_tile() {
        mount();
        provider.config = { pinned: ["fixture", "fixture", "other", "third"] };
        const duplicates = tiles().filter(item => item.modelData.appId === "fixture");
        compare(duplicates.length, 2);
        const retained = duplicates[0];
        retained.forceActiveFocus();
        provider.config = { pinned: ["fixture", "other", "third"] };
        compare(tiles().length, 3, "reducing repeated app keys removes the surplus delegate");
        compare(tile("A"), retained);
        verify(retained.activeFocus);
    }

}
