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
        function t(text) { return text; }
        function focusWindow(id) { calls = calls.concat([id]); }
        function closeWindow(id) { calls = calls.concat(["close " + id]); }
        function capabilityAvailable(id) { return true; }
        function capability(method, args, ok, fail) {
            ok({ apps: ["fixture", "other", "third"].map(id => ({ app_id: id, name: id, icon: "" })) });
        }
    }
    property var provider: null
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
}
