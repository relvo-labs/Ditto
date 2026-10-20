import QtQuick
import QtTest
import Quickshell.Networking
import DittoStub
import "../../../shell/jelly" as Jelly
import "../visual/.staged/network-fixture.js" as Fixture

TestCase {
    id: testCase
    name: "MixedNetworkManagers"
    width: 1280; height: 800
    visible: true
    when: windowShown
    Item { id: desktop; width: 1280; height: 800 }
    Jelly.Tokens { id: tokens }
    QtObject {
        id: client
        property var workspaces: []
        property var windows: []
        property var tr: ({ language: "zh-TW" })
        property bool online: true
        property string status: ""
        function t(text) { return text; }
        function capabilityAvailable(id) { return false; }
    }
    property var panel: null
    function control(action) {
        const request = new XMLHttpRequest();
        let done = false;
        request.onreadystatechange = function() {
            if (request.readyState === XMLHttpRequest.DONE) done = true;
        };
        request.open("GET", Fixture.endpoint + "/" + action);
        request.send();
        tryVerify(() => done);
        compare(request.status, 200);
    }
    SignalSpy { id: connectionChanges; target: panel; signalName: "networkConnectedChanged" }
    function readbacks() {
        const request = new XMLHttpRequest();
        let done = false;
        request.onreadystatechange = function() {
            if (request.readyState === XMLHttpRequest.DONE) done = true;
        };
        request.open("GET", Fixture.endpoint + "/readbacks");
        request.send();
        tryVerify(() => done);
        compare(request.status, 200);
        return Number(request.responseText);
    }
    function test_refresh_preserves_connected_snapshot() {
        const network = findChild(desktop, "panelNetwork");
        tryCompare(network, "connected", true);
        const before = readbacks();
        connectionChanges.clear();
        control("refresh");
        // Wait for the real D-Bus GetAll readback, not a fixed delay. Any
        // intermediate disconnect/reconnect changes remain in the signal spy.
        tryVerify(() => readbacks() > before);
        compare(network.connected, true);
        compare(connectionChanges.count, 0);
    }
    function init() {
        control("reset");
        StubDesktop.layer = desktop;
        StubDesktop.screenWidth = 1280;
        tokens.appearance = { theme: "soft-jelly-light", tokens: {} };
        // Exact Quickshell projection of the reported mixed-manager host:
        // NM State=20, Connectivity=0; enp0s1 unmanaged, not connected by NM.
        Networking.backend = NetworkBackendType.NetworkManager;
        Networking.connectivity = NetworkConnectivity.Unknown;
        Networking.devices = { values: [{ type: DeviceType.Wired, connected: false }] };
        const component = Qt.createComponent("../visual/.staged/providers/PanelTop.qml");
        compare(component.status, Component.Ready, component.errorString());
        panel = component.createObject(testCase, {client: client, tokens: tokens, shown: true});
        verify(panel !== null);
    }
    function cleanup() { panel.release(); panel.destroy(); wait(0); }
    function test_networkd_routable_while_nm_unmanaged() {
        // A private D-Bus networkd fixture reports configured/routable and a
        // routable address. This proves a link, never Internet availability.
        const network = findChild(desktop, "panelNetwork");
        verify(network !== null);
        tryCompare(network, "accessibleLabel", "網路已連線（網際網路狀態未知）");
        compare(network.iconName, "network-wired-symbolic");
        compare(network.marker, "?");
        const legacy = findChild(desktop, "panelNetworkLegacy");
        compare(legacy.text, network.accessibleLabel);
    }
    function test_failures_clear_the_networkd_connection_data() {
        return ["offline", "unknown", "unmanaged", "link-local", "fail", "timeout", "service-down"]
            .map(action => ({tag: action, action: action}));
    }
    function test_failures_clear_the_networkd_connection(row) {
        const network = findChild(desktop, "panelNetwork");
        tryCompare(network, "connected", true);
        control(row.action);
        tryCompare(network, "connected", false);
        compare(network.accessibleLabel, "網路狀態未知");
        compare(network.marker, "?");
        verify(panel.healthy());
        control("reset");
        tryCompare(network, "connected", true);
        compare(network.accessibleLabel, "網路已連線（網際網路狀態未知）");
    }
    function test_nm_precedence_and_hidden_release() {
        const network = findChild(desktop, "panelNetwork");
        const source = findChild(panel, "panelNetworkdSource");
        tryCompare(network, "connected", true);
        // Portal, limited and unknown are still NM's connectivity information;
        // a networkd link must never promote or replace them.
        for (const connectivity of [NetworkConnectivity.Full, NetworkConnectivity.Limited,
                                     NetworkConnectivity.Portal, NetworkConnectivity.Unknown]) {
            Networking.connectivity = connectivity;
            Networking.devices = {values: [{type: DeviceType.Wifi, connected: true}]};
            compare(network.iconName, "network-wireless-signal-excellent-symbolic");
            compare(network.accessibleLabel, "網路已連線");
            compare(source.active, false);
            compare(source.item, null);
        }
        Networking.devices = {values: [{type: DeviceType.Wired, connected: false}]};
        tryCompare(network, "connected", true);
        panel.shown = false;
        compare(source.active, false);
        compare(source.item, null);
        compare(panel.networkdConnected, false);
        panel.shown = true;
        tryCompare(network, "connected", true);
        panel.release();
        compare(source.item, null);
    }
    function test_nm_absent_networkd_connected() {
        Networking.backend = NetworkBackendType.None;
        Networking.devices = null;
        const network = findChild(desktop, "panelNetwork");
        tryCompare(network, "connected", true);
        compare(network.available, true);
        compare(network.iconName, "network-wired-symbolic");
        compare(network.accessibleLabel, "網路已連線（網際網路狀態未知）");
    }
    function test_optional_observer_failure_does_not_disable_panel() {
        const source = findChild(panel, "panelNetworkdSource");
        const network = findChild(desktop, "panelNetwork");
        tryCompare(network, "connected", true);
        // A package missing its optional observer must keep the panel and NM.
        source.source = Qt.resolvedUrl("missing-observer.qml");
        tryCompare(source, "status", Loader.Error);
        tryCompare(network, "connected", false);
        verify(panel.healthy());
        compare(network.accessibleLabel, "網路狀態未知");
        Networking.devices = {values: [{type: DeviceType.Wifi, connected: true}]};
        compare(network.iconName, "network-wireless-signal-excellent-symbolic");
        compare(network.accessibleLabel, "網路已連線");
    }
}
