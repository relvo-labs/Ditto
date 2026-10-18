import QtQuick
import QtTest
import DittoStub
import "../../../shell/jelly" as Jelly

// Fixture projections; assertions observe the actual provider animation and
// rendered delegates, including recreation. No Core / compositor focus proof.
TestCase {
    id: testCase
    name: "DockFocusIdentity"
    width: 1280; height: 800
    visible: true
    when: windowShown
    Item { id: layer; width: 1280; height: 800 }
    Jelly.Tokens { id: tokens }
    QtObject {
        id: client
        property var windows: []
        /// undefined = fixture without a connection state (always a snapshot).
        property var online: undefined
        function t(text) { return text; }
        function capability(method, args, ok, fail) {
            ok({ apps: [{ app_id: "fixture", name: "Fixture", icon: "" },
                { app_id: "other", name: "Other", icon: "" }] });
        }
    }
    property var provider: null
    SignalSpy { id: starts; target: provider ? provider.confirmationAnimation : null; signalName: "started" }
    function windows(id) {
        return ["A", "B", "C"].map((key, index) => ({ id: key,
            app_id: index === 0 ? "fixture" : "other", focused: key === id, title: key, x: 0, y: 0, width: 640, height: 480 }));
    }
    function mount(initial, theme, online) {
        StubDesktop.layer = layer;
        client.online = online;
        tokens.appearance = { theme: theme || "soft-jelly-light" };
        client.windows = initial;
        const component = Qt.createComponent(Qt.resolvedUrl("../visual/.staged/providers/DockPill.qml"));
        compare(component.status, Component.Ready, component.errorString());
        const incubator = component.incubateObject(testCase, { client: client, tokens: tokens,
            config: { pinned: ["fixture", "other"] }, shown: false });
        incubator.forceCompletion();
        provider = incubator.object;
        verify(!!provider);
        wait(0);
        starts.clear();
        provider.shown = true;
        wait(220);
    }
    function cleanup() {
        if (provider) { provider.release(); provider.destroy(); }
        provider = null;
        client.online = undefined;
        wait(10);
    }
    function matchingTiles(id) {
        const result = [];
        function visit(item) {
            for (const child of item.children || []) {
                if (child.objectName.indexOf("dockTile_") === 0 && child.modelData.window && child.modelData.window.id === id)
                    result.push(child);
                visit(child);
            }
        }
        visit(layer);
        return result;
    }
    function tile(id) {
        const matches = matchingTiles(id);
        verify(matches.length > 0, "window tile " + id);
        return matches[0];
    }
    function project(id) {
        client.windows = windows(id);
        compare(provider.focusedWindowId, id); // actual projected ID, not delegate lifetime
        compare(provider.observedFocusId, id);
    }
    function active(id, count) {
        compare(starts.count, count);
        compare(provider.confirmationWindowId, id);
        verify(provider.confirmationAnimation.running);
        verify(tile(id).confirmedScale < 1);
        compare(matchingTiles(id).filter(item => item.confirmedScale < 1).length, 1);
    }
    function retired(count) {
        compare(starts.count, count);
        compare(provider.confirmationAnimation.running, false);
        compare(provider.focusScale, 1);
    }
    function test_T01_initial_observation_data() {
        return [{ tag: "empty", id: "" }, { tag: "focused", id: "A" },
            { tag: "legacy-focused", id: "A", theme: "soft-jelly" }];
    }
    function test_T01_initial_observation(data) {
        mount(data.id ? windows(data.id) : [], data.theme);
        compare(provider.observedFocusId, data.id);
        retired(0);
        if (data.id) compare(tile(data.id).confirmedScale, 1);
    }
    function test_T02_T03_real_transition_loss_and_regain() {
        mount([]);
        project("A"); active("A", 1);
        project("B"); active("B", 2);
        compare(tile("A").confirmedScale, 1);
        project(""); retired(2);
        compare(provider.confirmationWindowId, "");
        project("B"); active("B", 3);
        tryCompare(provider, "focusScale", 1);
        retired(3);
    }
    function test_T04_T07_identity_preserving_rebuild_data() {
        return ["title", "geometry-size", "unrelated-open", "unrelated-close", "apps-reload", "apps-reorder", "pinned-reorder"]
            .map(kind => ({ tag: kind, kind: kind }));
    }
    function test_T04_T07_identity_preserving_rebuild(data) {
        mount(windows("A"));
        if (data.kind === "title") client.windows = client.windows.map(w => Object.assign({}, w, { title: "changed " + w.id }));
        if (data.kind === "geometry-size") client.windows = client.windows.map(w => Object.assign({}, w, { x: 10, y: 20, width: 900, height: 700 }));
        if (data.kind === "unrelated-open") client.windows = client.windows.concat([{ id: "Z", app_id: "new", focused: false }]);
        if (data.kind === "unrelated-close") client.windows = client.windows.filter(w => w.id !== "C");
        if (data.kind === "apps-reload") { provider.appsLoaded = false; provider.loadApps(); }
        if (data.kind === "apps-reorder") provider.apps = provider.apps.slice().reverse();
        if (data.kind === "pinned-reorder") provider.config = { pinned: ["other", "fixture"] };
        wait(30);
        compare(provider.observedFocusId, "A");
        retired(0);
        compare(tile("A").confirmedScale, 1);
        compare(tile("A").motionRunning, false);
    }
    function test_T04_T07_rebuild_during_confirmation_continues_without_restart() {
        mount(windows("A"));
        project("B"); active("B", 1);
        wait(40);
        const progress = provider.focusScale;
        const animation = provider.confirmationAnimation;
        verify(progress > 0.94 && progress < 1);
        client.windows = client.windows.map(w => Object.assign({}, w, { title: "new title", x: 5 }));
        provider.apps = provider.apps.slice().reverse();
        wait(30);
        compare(provider.confirmationAnimation, animation);
        compare(starts.count, 1);
        verify(provider.focusScale >= progress, "provider progress does not restart with delegates");
        compare(tile("B").confirmedScale, provider.focusScale);
        tryCompare(provider, "focusScale", 1);
        retired(1);
    }
    function test_T08_T11_T14_eligibility_data() {
        return ["hidden", "reduced-motion", "low-power", "legacy"].map(kind => ({ tag: kind, kind: kind }));
    }
    function test_T08_T09_same_id_restore_data() {
        return ["hidden", "reduced-motion", "low-power"].map(kind => ({ tag: kind, kind: kind }));
    }
    function test_T08_T09_same_id_restore(data) {
        mount(windows("A"));
        project("B"); active("B", 1);
        wait(30);
        if (data.kind === "hidden") provider.shown = false;
        else tokens.appearance = { theme: "soft-jelly-light", reduced_motion: data.kind === "reduced-motion", low_power_style: data.kind === "low-power" };
        retired(1);
        provider.shown = true;
        tokens.appearance = { theme: "soft-jelly-light" };
        wait(220);
        compare(provider.observedFocusId, "B");
        retired(1);
        compare(tile("B").confirmedScale, 1);
    }
    function test_T08_T11_T14_eligibility(data) {
        mount(windows("A"));
        project("B"); active("B", 1);
        wait(30);
        if (data.kind === "hidden") provider.shown = false;
        else if (data.kind === "legacy") tokens.appearance = { theme: "soft-jelly" };
        else tokens.appearance = { theme: "soft-jelly-light", reduced_motion: data.kind === "reduced-motion", low_power_style: data.kind === "low-power" };
        retired(1);
        project("C"); retired(1); // observe, never enqueue while ineligible
        provider.shown = true;
        tokens.appearance = { theme: "soft-jelly-light" };
        wait(220);
        retired(1); // hide→show / preference restore never replays C
        compare(tile("C").confirmedScale, 1);
        project("A"); active("A", 2); // genuine eligible transitions still animate
    }
    function test_T12_same_app_two_window_identity() {
        mount([{ id: "A", app_id: "fixture", focused: true }, { id: "B", app_id: "fixture", focused: false }]);
        client.windows = [{ id: "A", app_id: "fixture", focused: false }, { id: "B", app_id: "fixture", focused: true }];
        active("B", 1);
        compare(tile("A").confirmedScale, 1);
        client.windows = [{ id: "B", app_id: "fixture", focused: false }, { id: "A", app_id: "fixture", focused: true }];
        active("A", 2);
        compare(tile("B").confirmedScale, 1);
    }
    function test_T12_one_target_when_alias_tiles_share_a_window() {
        mount([]);
        provider.config = { pinned: ["fixture", "org.example.fixture"] };
        client.windows = [{ id: "A", app_id: "fixture", focused: true }];
        compare(matchingTiles("A").length, 2);
        active("A", 1);
    }
    function test_T13_rapid_burst_latest_id_only() {
        mount(windows("A"));
        project("B"); active("B", 1);
        project("A"); active("A", 2);
        client.windows = windows("A").map(w => Object.assign({}, w, { title: "same identity" }));
        project("C"); active("C", 3);
        client.windows = windows("C").map(w => Object.assign({}, w, { x: 100 }));
        wait(30);
        active("C", 3);
        compare(tile("A").confirmedScale, 1);
        compare(tile("B").confirmedScale, 1);
        wait(220);
        retired(3);
        compare(provider.confirmationWindowId, "C");
    }

    // #84: the baseline is the first Core snapshot, not component load.
    // Same order as DittoClient.subscribe(): windows first, then online.
    function arriveSnapshot(list) {
        client.windows = list;
        client.online = true;
    }
    function test_T15_dock_shown_before_first_snapshot() {
        mount([], undefined, false);
        arriveSnapshot(windows("A"));
        compare(provider.observedFocusId, "A");
        wait(30);
        retired(0);
        compare(tile("A").confirmedScale, 1);
        project("B"); active("B", 1); // later genuine transitions still animate
    }
    function test_T15_snapshot_before_dock() {
        mount(windows("A"), undefined, true);
        compare(provider.observedFocusId, "A");
        retired(0);
        project("B"); active("B", 1);
    }
    function test_T16_reconnect_rebaselines_without_replay_data() {
        return [{ tag: "same-focus", id: "A" }, { tag: "focus-changed-while-offline", id: "B" },
            { tag: "nothing-focused-after", id: "" }];
    }
    function test_T16_reconnect_rebaselines_without_replay(data) {
        mount(windows("A"), undefined, true);
        client.online = false; // disconnect keeps the stale list
        arriveSnapshot(data.id ? windows(data.id) : []);
        compare(provider.observedFocusId, data.id);
        wait(30);
        retired(0);
        project("C"); active("C", 1);
    }
    function test_T16_disconnect_settles_running_confirmation() {
        mount(windows("A"), undefined, true);
        project("B"); active("B", 1);
        client.online = false;
        retired(1);
        compare(provider.confirmationWindowId, "");
        arriveSnapshot(windows("B"));
        wait(30);
        retired(1);
    }
}
