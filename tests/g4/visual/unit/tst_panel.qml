import QtQuick
import QtTest
import Quickshell
import Quickshell.Services.Pipewire
import Quickshell.Networking
import DittoStub
import "../../../../shell/jelly" as Jelly

// Actual provider; layer-shell, system services and Core are fixtures.
TestCase {
    id: testCase
    name: "PanelTopRecipe"
    width: 1280; height: 800
    visible: true
    when: windowShown
    Item { id: desktop; width: 1280; height: 800 }
    Jelly.Tokens { id: tokens }
    QtObject {
        id: client
        property bool online: true
        property string status: "offline fixture"
        property bool allowed: true
        property var calls: []
        property var windows: [{ id: "w1", title: "Focused fixture", focused: true }]
        property var workspaces: [
            { id: "1", name: "1", active: true }, { id: "2", name: "2", active: false },
            { id: "3", name: "3", active: false }, { id: "4", name: "4", active: false }
        ]
        function t(text) { return text; }
        function capabilityAvailable(id) { return allowed; }
        function activateWorkspace(id) { calls = calls.concat([id]); }
        function launchApp(id) { calls = calls.concat([id]); }
        function capability(id, args) { calls = calls.concat([id + ":" + (args.command_id || "")]); }
    }
    QtObject { id: audio; property bool muted: false; property real volume: 0.5 }
    QtObject { id: sink; property var audio: testCase.audioObject }
    readonly property var audioObject: audio
    property var mounted: []
    property date comparisonTime: new Date()
    function init() {
        StubDesktop.layer = desktop;
        StubDesktop.screenWidth = 1280;
        tokens.appearance = { theme: "soft-jelly-light", tokens: {} };
        client.allowed = true; client.online = true; client.calls = [];
        comparisonTime = new Date();
        Pipewire.ready = false; Pipewire.defaultAudioSink = null;
        Networking.backend = NetworkBackendType.None;
        Networking.connectivity = NetworkConnectivity.Unknown;
        Networking.devices = null;
        audio.muted = false; audio.volume = 0.5;
        Quickshell.iconMap = {};
    }
    function cleanup() {
        for (const p of mounted) { p.release(); p.destroy(); }
        mounted = [];
        wait(0);
    }
    function mount(base) {
        const c = Qt.createComponent(Qt.resolvedUrl(base ? "../.staged/base/PanelTop.qml" : "../.staged/providers/PanelTop.qml"));
        verify(c.status === Component.Ready, c.errorString());
        const p = c.createObject(testCase, { client: client, tokens: tokens, shown: true });
        verify(p !== null);
        // The legacy pixel oracle fixes both stub clocks to the same captured
        // instant; mounting across a minute boundary must not compare two times.
        if (!tokens.lightRecipe) p.data.find(x => x.precision !== undefined).date = comparisonTime;
        mounted.push(p);
        wait(20);
        return p;
    }
    function item(name) {
        const found = findChild(desktop, name);
        verify(found !== null, name + " exists");
        return found;
    }
    function test_geometry_and_region() {
        const p = mount();
        const capsule = item("panelWorkspaces");
        compare(capsule.x + capsule.width / 2, 640);
        compare(capsule.y, 4); compare(capsule.width, 144); compare(capsule.height, 28);
        const status = item("panelStatus");
        compare(status.x + status.width, 1262);
        verify(status.x > capsule.x + capsule.width + 8);
        compare(item("panelTitle").text, "Focused fixture");
        verify(p.statusRegion === item("panelStatusItems"));
        const window = p.data.find(x => x.exclusiveZone !== undefined);
        compare(window.exclusiveZone, 36); compare(window.height, 36);
        verify(window.mask !== null);
        verify(!window.mask.contains(0, 0));
        verify(!window.mask.contains(500, 18));
        verify(window.mask.contains(640, 18));
        verify(!window.mask.contains(capsule.x, capsule.y));
        p.release(); compare(window.exclusiveZone, 0);
    }
    function test_workspace_capability_and_keyboard() {
        mount();
        const button = item("panelWorkspace_2");
        button.forceActiveFocus(); keyClick(Qt.Key_Return); keyClick(Qt.Key_Space);
        mouseClick(button); compare(client.calls, ["2", "2", "2"]);
        client.allowed = false;
        button.forceActiveFocus(); keyClick(Qt.Key_Return); keyClick(Qt.Key_Space); mouseClick(button);
        compare(client.calls, ["2", "2", "2"]);
    }
    function test_status_states_and_fallback() {
        mount();
        const volume = item("panelVolume"); const network = item("panelNetwork");
        compare(volume.Accessible.name, "音量不可用");
        compare(network.Accessible.name, "網路不可用");
        verify(item("panelVolumeFallback").visible);
        const unavailable = volume.iconName;
        Pipewire.ready = true; Pipewire.defaultAudioSink = sink;
        compare(volume.Accessible.name, "音量 50%");
        verify(volume.iconName !== unavailable);
        audio.muted = true;
        compare(volume.Accessible.name, "音量 靜音");
        compare(volume.iconName, "audio-volume-muted-symbolic");
        Networking.backend = NetworkBackendType.NetworkManager;
        compare(network.Accessible.name, "網路狀態未知");
        const unknown = network.iconName;
        Networking.connectivity = NetworkConnectivity.None;
        Networking.devices = { values: [{ connected: false }] };
        compare(network.Accessible.name, "網路未連線");
        verify(network.iconName !== unknown);
        Networking.devices = { values: [{ connected: true }] };
        compare(network.Accessible.name, "網路已連線");
        Quickshell.iconMap = {
            "audio-volume-muted-symbolic": Qt.resolvedUrl("../fixtures/test-icon.svg"),
            "network-wireless-signal-excellent-symbolic": Qt.resolvedUrl("../fixtures/test-icon.svg")
        };
        tryCompare(item("panelVolumeIcon"), "status", Image.Ready);
        tryCompare(item("panelNetworkIcon"), "status", Image.Ready);
        verify(!item("panelVolumeFallback").visible);
        verify(!item("panelNetworkFallback").visible);
        Quickshell.iconMap = {};
        tryVerify(() => item("panelNetworkFallback").visible);
        verify(item("panelNetworkFallback").text.length > 0);
    }
    function test_motion_focus_and_actions() {
        const p = mount();
        const button = item("panelWorkspace_2");
        button.forceActiveFocus();
        tryCompare(button, "feedbackScale", 0.96);
        verify(item("panelWorkspace_2_focus").visible);
        mousePress(button);
        tryCompare(button, "feedbackScale", 0.90);
        tokens.appearance = { theme: "soft-jelly-light", reduced_motion: true, tokens: {} };
        verify(!button.motionRunning);
        mouseRelease(button);
        compare(button.feedbackScale, 0.96);
        const menu = item("panelMenu");
        menu.forceActiveFocus(); keyClick(Qt.Key_Space); compare(p.menuOpen, true);
        const entries = [];
        function walk(root) {
            for (const child of root.children) {
                if (child.visible && child.Accessible.role === Accessible.MenuItem) entries.push(child);
                walk(child);
            }
        }
        walk(desktop);
        compare(entries.length, 9);
        entries[1].forceActiveFocus(); keyClick(Qt.Key_Return);
        verify(client.calls.indexOf("desktop.commands.invoke:composition.open") >= 0);
        item("panelVolume").forceActiveFocus(); keyClick(Qt.Key_Return);
        verify(client.calls.indexOf("pavucontrol") >= 0);
        item("panelNetwork").forceActiveFocus(); keyClick(Qt.Key_Space);
        verify(client.calls.indexOf("nm-connection-editor") >= 0);
    }
    function test_legacy_pixels() {
        for (const appearance of [null, { theme: "soft-jelly", tokens: {} }, { theme: "other", tokens: {} }]) {
            tokens.appearance = appearance;
            const base = mount(true);
            waitForRendering(desktop);
            const before = grabImage(desktop);
            base.release(); base.destroy(); mounted = []; wait(20);
            const current = mount();
            waitForRendering(desktop);
            const after = grabImage(desktop);
            verify(before.equals(after), "legacy panel pixels match bound base");
            current.release(); current.destroy(); mounted = []; wait(20);
        }
    }
}
