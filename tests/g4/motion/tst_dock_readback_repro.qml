import QtQuick
import QtTest
import DittoStub
import "../../../shell/jelly" as Jelly

TestCase {
    id: testCase
    name: "DockReadbackRepro"
    width: 1280; height: 800
    visible: true
    when: windowShown
    Item { id: layer; width: 1280; height: 800 }
    MouseArea { id: other; width: 40; height: 40; hoverEnabled: true }
    Jelly.Tokens { id: tokens }
    QtObject {
        id: client
        property var windows: []
        property var calls: []
        function t(text) { return text; }
        function focusWindow(id) { calls = calls.concat(["focus " + id]); }
        function launchApp(id, ok, fail) { calls = calls.concat(["launch " + id]); }
        function capability(method, args, ok, fail) { ok({ apps: [{ app_id: "fixture", name: "Fixture", icon: "" }] }); }
    }
    property var provider: null
    function init() {
        StubDesktop.layer = layer;
        tokens.appearance = { theme: "soft-jelly-light" };
        client.windows = [];
        const component = Qt.createComponent(Qt.resolvedUrl("../visual/.staged/providers/DockPill.qml"));
        compare(component.status, Component.Ready, component.errorString());
        const inc = component.incubateObject(testCase, { client: client, tokens: tokens, config: { pinned: ["fixture"] }, shown: false });
        inc.forceCompletion();
        provider = inc.object;
        provider.shown = true;
        wait(250);
        other.forceActiveFocus();
    }
    function cleanup() { provider.release(); provider.destroy(); provider = null; wait(10); }
    function tile() { return findChild(layer, "dockTile_fixture"); }
    // Window already focused; a non-focus window_upsert (title change) arrives.
    function test_title_upsert_replays_focus_feedback() {
        client.windows = [{ id: "w1", app_id: "fixture", title: "a", focused: true }];
        wait(300);
        const before = tile();
        compare(before.confirmedScale, 1);
        compare(before.current, true);
        // Same window, still focused; only the title changed (DittoClient window_upsert).
        client.windows = client.windows.filter(w => w.id !== "w1").concat([{ id: "w1", app_id: "fixture", title: "b", focused: true }]);
        const after = tile();
        console.log("REPRO same delegate:", before === after, "confirmationRunning:", after.motionRunning, "confirmedScale:", after.confirmedScale);
        wait(30);
        console.log("REPRO +30ms confirmedScale:", tile().confirmedScale);
        verify(tile().confirmedScale === 1 && !tile().motionRunning, "focused-state readback replayed without any focus transition");
    }
    // An unrelated second window opens/upserts while fixture remains focused.
    function test_unrelated_window_upsert() {
        client.windows = [{ id: "w1", app_id: "fixture", title: "a", focused: true }];
        wait(300);
        client.windows = client.windows.concat([{ id: "w2", app_id: "other", title: "x", focused: false }]);
        wait(30);
        console.log("REPRO unrelated upsert confirmedScale:", tile().confirmedScale);
        verify(tile().confirmedScale === 1, "unrelated window upsert replays focused bounce");
    }
    // Hover state across upsert.
    function test_initial_show_with_focused_window() {
        provider.shown = false;
        client.windows = [{ id: "w1", app_id: "fixture", title: "a", focused: true }];
        wait(50);
        provider.shown = true;
        wait(30);
        console.log("REPRO show-with-focused confirmedScale:", tile().confirmedScale);
    }

    function test_drag_geometry_stream() {
        client.windows = [{ id: "w1", app_id: "fixture", title: "a", focused: true, x: 0 }];
        wait(300);
        let min = 1, running = 0;
        for (let i = 0; i < 20; ++i) {
            client.windows = [{ id: "w1", app_id: "fixture", title: "a", focused: true, x: i * 10 }];
            wait(30);
            min = Math.min(min, tile().confirmedScale);
            if (tile().motionRunning) running++;
        }
        console.log("REPRO drag stream 20 upserts/600ms: samples running=" + running + "/20 min confirmedScale=" + min);
        verify(running === 0, "geometry-only upserts keep replaying focus confirmation");
    }
}
