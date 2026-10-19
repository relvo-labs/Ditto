import QtQuick
import QtQuick.Window
import QtTest
import Quickshell
import Quickshell.Services.Pipewire
import Quickshell.Networking
import DittoStub
import "../../../../shell/jelly" as Jelly
import "../.staged/capture-data.js" as Data

// #105 C3: the light status capsule grabbed at the window's device pixel
// ratio, next to a plain Image raster of the same real Yaru SVGs on the same
// fill. run.sh runs this file once with the scale-1 captures and once with
// QT_SCALE_FACTOR=2; capture/check_hidpi.py compares the recoloured glyphs
// with the direct raster pixel by pixel. Labelled service fixtures. Offscreen
// software rendering: development evidence, not a reference-machine capture.
TestCase {
    id: testCase
    name: "CaptureHiDpiStatus"
    width: 1280
    height: 120
    visible: true
    when: windowShown

    readonly property string outDir: Qt.resolvedUrl("../.staged/out/").toString().replace("file://", "")
    readonly property real ratio: Screen.devicePixelRatio

    Item { id: layer; width: 1280; height: 60 }
    Rectangle {
        id: reference
        y: 60
        width: 400
        height: 40
        property var names: []
        Repeater {
            model: reference.names
            Image {
                required property var modelData
                required property int index
                x: 10 + index * 40
                y: 11
                width: 18
                height: 18
                // Qt rasterises a scalable source at sourceSize × device ratio.
                sourceSize: Qt.size(18, 18)
                source: Data.yaruIconMap[modelData]
            }
        }
    }

    Jelly.Tokens { id: sceneTokens; appearance: ({ theme: "soft-jelly-light", tokens: {}, locale: "zh-TW" }) }
    QtObject { id: fixtureAudio; property bool muted: false; property real volume: 1 }
    QtObject { id: fixtureSink; property var audio: fixtureAudio }
    QtObject {
        id: client
        property bool online: true
        property string status: ""
        property var windows: []
        property var workspaces: [{ id: "1", name: "1", active: true }]
        function t(text) { return text; }
        function capabilityAvailable(id) { return true; }
        function activateWorkspace(id) {}
        function launchApp(id) {}
    }

    function rect(item, root) {
        const p = item.mapToItem(root, 0, 0);
        return { x: p.x, y: p.y, width: item.width, height: item.height };
    }

    function grab(item, path) {
        let result = null;
        item.grabToImage(r => { result = r; });
        tryVerify(() => result !== null, 3000, "grab " + path);
        verify(result.saveToFile(path), path);
    }

    function scene(tag, muted, devices) {
        fixtureAudio.muted = muted;
        Networking.devices = { values: devices };
        const component = Qt.createComponent(Qt.resolvedUrl("../.staged/providers/PanelTop.qml"));
        verify(component.status === Component.Ready, component.errorString());
        const panel = component.createObject(testCase, { client: client, tokens: sceneTokens, shown: true });
        const capsule = findChild(layer, "panelStatus");
        const icons = ["panelNetwork", "panelVolume"].map(name => findChild(layer, name + "Icon"));
        tryVerify(() => icons.every(icon => icon.status === Image.Ready && icon.painted), 5000, "icons painted");
        const names = ["panelNetwork", "panelVolume"].map(name => findChild(layer, name).iconName);
        reference.color = sceneTokens.reducedTransparency ? sceneTokens.surface
            : Qt.rgba(sceneTokens.surface.r, sceneTokens.surface.g, sceneTokens.surface.b, 1);
        reference.names = names;
        waitForRendering(reference);
        tryVerify(() => reference.children.filter(child => child.status !== undefined).every(child => child.status === Image.Ready));
        wait(50);
        const suffix = tag + "-" + ratio + "x.png";
        grab(capsule, outDir + "panel-status-" + suffix);
        grab(reference, outDir + "panel-status-reference-" + suffix);
        console.log("HIDPI_META " + JSON.stringify({
            scene: tag, device_pixel_ratio: ratio,
            capture: "panel-status-" + suffix, reference: "panel-status-reference-" + suffix,
            capsule: { width: capsule.width, height: capsule.height },
            reference_size: { width: reference.width, height: reference.height },
            fixture: { muted: muted, volume: fixtureAudio.volume, devices: devices },
            icons: icons.map((icon, index) => ({
                name: names[index], source: String(icon.source), glyph: rect(icon, capsule),
                reference_glyph: { x: 10 + index * 40, y: 11, width: 18, height: 18 },
                raised: icon.normalized, source_peak_alpha: icon.peakAlpha,
                device_size: [icon.deviceWidth, icon.deviceHeight] }))
        }));
        panel.release();
        panel.destroy();
        wait(50);
    }

    function initTestCase() {
        StubDesktop.layer = layer;
        StubDesktop.screenWidth = 1280;
        StubDesktop.screenHeight = 800;
        Quickshell.iconMap = Data.yaruIconMap;
        Pipewire.ready = true;
        Pipewire.defaultAudioSink = fixtureSink;
        Networking.backend = NetworkBackendType.NetworkManager;
        Networking.connectivity = NetworkConnectivity.Full;
    }

    // Opaque glyphs: the sharpness oracle.
    function test_1_wired_high() {
        scene("wired-high", false, [{ type: DeviceType.Wired, connected: true }]);
    }

    // Dim-only Yaru glyphs raised by the minimum-alpha rule, and the marker.
    function test_2_offline_muted() {
        Networking.connectivity = NetworkConnectivity.None;
        scene("offline-muted", true, [{ type: DeviceType.Wifi, connected: false }]);
        Networking.connectivity = NetworkConnectivity.Full;
    }
}
