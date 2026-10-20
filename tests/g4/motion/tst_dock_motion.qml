import QtQuick
import QtTest
import DittoStub
import "../../../shell/jelly" as Jelly

TestCase {
    id: testCase
    name: "DockNativeMotion"
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
        function capability(method, args, ok, fail) {
            ok({ apps: [{ app_id: "fixture", name: "Fixture", icon: "" }] });
        }
    }
    property var provider: null
    function init() {
        StubDesktop.layer = layer;
        tokens.appearance = { theme: "soft-jelly-light" };
        client.windows = [];
        client.calls = [];
        const component = Qt.createComponent(Qt.resolvedUrl("../visual/.staged/providers/DockPill.qml"));
        compare(component.status, Component.Ready, component.errorString());
        const incubator = component.incubateObject(testCase, { client: client, tokens: tokens,
            config: { pinned: ["fixture"] }, shown: false });
        incubator.forceCompletion();
        provider = incubator.object;
        verify(!!provider);
        provider.shown = true;
        wait(220);
        other.forceActiveFocus();
    }
    function cleanup() { provider.release(); provider.destroy(); provider = null; wait(10); }
    function tile() { return findChild(layer, "dockTile_fixture"); }
    // The fallback that is drawn: the light recipe shows the application
    // style the Profile chose (#116, J1 by default), whose fallback is the
    // themed squircle; the earlier lettered tile is hidden then.
    function icon() { return findChild(tile(), provider.jelly ? "dockIconSquircle" : "dockIconFallback"); }
    function test_click_is_not_launch_success_and_readback_is_feedback() {
        mousePress(tile(), 26, 26);
        wait(35);
        verify(icon().scale < 1 && icon().scale > 0.89);
        mouseRelease(tile(), 26, 26);
        compare(client.calls, ["launch fixture"]);
        compare(tile().confirmedScale, 1); // no optimistic completion
        mouseClick(tile(), 26, 26);
        compare(client.calls.length, 2); // no settling barrier or automatic replay
        client.windows = [{ id: "fixture-window", app_id: "fixture", focused: true }];
        const currentTile = tile(); // the existing model may rebuild the delegate
        tryVerify(() => currentTile.confirmedScale < 1);
        tryCompare(currentTile, "confirmedScale", 1);
        compare(findChild(currentTile, "dockIndicator").width, provider.jelly ? 18 : 16);
        compare(currentTile.Accessible.name, "Fixture（使用中）（已釘選）");
        compare(client.calls.length, 2);
    }
    function test_live_fallback_hidden_and_position_cleanup() {
        const currentTile = tile();
        const capsule = findChild(layer, "dockCapsule");
        const panel = provider.data.find(item => item.mask !== undefined && item.mask !== null);
        currentTile.forceActiveFocus();
        wait(30);
        verify(currentTile.motionRunning);
        tokens.appearance = { theme: "soft-jelly-light", reduced_motion: true };
        compare(currentTile.motionRunning, false);
        compare(icon().scale, 0.96);
        compare(panel.mask.item, capsule);
        verify(!panel.mask.contains(1, 1));
        const description = currentTile.Accessible.name;
        keyClick(Qt.Key_Return);
        compare(client.calls.length, 1);
        tokens.appearance = { theme: "soft-jelly-light" };
        other.forceActiveFocus();
        wait(25);
        provider.config = { position: "left", pinned: ["fixture"] };
        compare(currentTile.motionRunning, false);
        compare(provider.reveal, 1);
        currentTile.forceActiveFocus();
        wait(25);
        provider.shown = false;
        compare(currentTile.motionRunning, false);
        compare(currentTile.confirmedScale, 1);
        compare(provider.reveal, 1);
        compare(panel.exclusiveZone, 0);
        verify(!capsule.visible);
        compare(currentTile.Accessible.name, description);
    }
    function test_focus_reverse() {
        const currentTile = tile();
        currentTile.forceActiveFocus();
        wait(35);
        verify(icon().scale < 1 && icon().scale > 0.95);
        other.forceActiveFocus();
        wait(20);
        currentTile.forceActiveFocus();
        tryCompare(icon(), "scale", 0.96);
        other.forceActiveFocus();
        tryCompare(icon(), "scale", 1);
        compare(client.calls.length, 0);
    }
    function test_static_capture_settles_enabled_motion() {
        provider.shown = false;
        provider.shown = true;
        verify(tokens.motionEnabled);
        verify(provider.revealAnimation.running);
        tryCompare(provider, "reveal", 1);
        tryVerify(() => !tile().motionRunning);
        const settled = grabImage(layer);
        wait(100);
        verify(settled.equals(grabImage(layer)), "settled native pixels are stable with motion enabled");
        verify(tokens.motionEnabled); // capture never changes production policy
    }
}
