import QtQuick
import QtTest
import Quickshell
import Quickshell.Services.Pipewire
import Quickshell.Networking
import DittoStub
import "../../../../shell/jelly" as Jelly
import "../.staged/capture-data.js" as Data

// #105 C1/C2 scenes of the light top bar, for review: narrow widths with the
// reviewer's worst cases, the menu opened from a wrapped bar, and a tooltip.
// The dashed line (harness overlay, not product) marks the bottom of the
// panel window; the tooltip and menu are popup surfaces of their own. Labelled
// fixtures: workspace lists, two 40 px status items, a long window title.
// Offscreen software rendering: development evidence, not a reference machine.
TestCase {
    id: testCase
    name: "CapturePanelScenes"
    width: 1280
    height: 260
    visible: true
    when: windowShown

    readonly property string outDir: Qt.resolvedUrl("../.staged/out/").toString().replace("file://", "")

    Item {
        id: screen
        width: 1280
        height: 260
        Jelly.Backdrop { anchors.fill: parent; tokens: sceneTokens; wallpaperSource: "" }
        Item { id: layer; anchors.fill: parent }
        Rectangle {
            id: windowEdge
            z: 100
            width: parent.width
            height: 1
            color: "transparent"
            Row {
                Repeater {
                    model: 160
                    Rectangle { width: 4; height: 1; color: "#d0103a" }
                }
                spacing: 4
            }
        }
    }

    Jelly.Tokens { id: sceneTokens; appearance: ({ theme: "soft-jelly-light", tokens: {}, locale: "zh-TW" }) }
    QtObject {
        id: client
        property bool online: true
        property string status: ""
        property var tr: ({ language: "zh-TW" })
        property var windows: [{ id: "fixture", focused: true,
            title: "一個很長的視窗標題（fixture）— a long window title used to check wrapping" }]
        property var workspaces: []
        function t(text) { return text; }
        function capabilityAvailable(id) { return true; }
        function activateWorkspace(id) {}
        function launchApp(id) {}
        function capability(method, args, ok, fail) { if (fail) fail({ name: "unavailable", message: method }); }
    }

    function rect(item) {
        const p = item.mapToItem(screen, 0, 0);
        return { x: Math.round(p.x), y: Math.round(p.y), width: Math.round(item.width), height: Math.round(item.height) };
    }

    function scene(tag, width, scale, count, icons, members, action) {
        StubDesktop.layer = layer;
        StubDesktop.screenWidth = width;
        screen.width = width;
        sceneTokens.appearance = { theme: "soft-jelly-light", tokens: { font_scale: scale }, locale: "zh-TW" };
        client.workspaces = Array.from({ length: count }, (_, i) => ({ id: String(i + 1), name: String(i + 1), active: i === 0 }));
        Quickshell.iconMap = icons ? Data.yaruIconMap : {};
        const component = Qt.createComponent(Qt.resolvedUrl("../.staged/providers/PanelTop.qml"));
        verify(component.status === Component.Ready, component.errorString());
        const panel = component.createObject(testCase, { client: client, tokens: sceneTokens, shown: true });
        for (let i = 0; i < members; ++i)
            Qt.createQmlObject('import QtQuick; Rectangle { width: ' + (40 * scale) + '; height: 18; radius: 9; color: "#9d8cf0" }',
                               panel.statusRegion);
        if (icons)
            tryVerify(() => ["panelNetworkIcon", "panelVolumeIcon"].every(name => findChild(layer, name).painted), 5000);
        wait(50);
        const window = panel.data.find(x => x.exclusiveZone !== undefined);
        windowEdge.y = window.height;
        let extra = {};
        if (action === "menu") {
            panel.menuOpen = true;
            wait(50);
        } else if (action === "tooltip") {
            const volume = findChild(layer, "panelVolume");
            mouseMove(volume, volume.width / 2, volume.height / 2);
            tryVerify(() => findChild(layer, "panelTooltip").visible, 3000, "tooltip shown");
            extra = { tooltip: rect(findChild(layer, "panelTooltip")), tooltip_text: findChild(layer, "panelTooltipText").text };
        } else if (action === "long-tooltip") {
            findChild(layer, "panelMenu").forceActiveFocus();
            tryVerify(() => findChild(layer, "panelTooltip").visible, 3000, "tooltip shown");
            extra = { tooltip: rect(findChild(layer, "panelTooltip")), tooltip_lines: findChild(layer, "panelTooltipText").lineCount };
        }
        waitForRendering(screen);
        const path = outDir + "panel-scene-" + tag + ".png";
        grabImage(screen).save(path);
        const capsules = ["panelLeft", "panelWorkspaces", "panelStatus"].map(name => rect(findChild(layer, name)));
        const menu = panel.data.find(x => x.anchor !== undefined && x.objectName !== "panelTooltipWindow");
        console.log("SCENE_META " + JSON.stringify(Object.assign({
            scene: tag, file: "panel-scene-" + tag + ".png", screen_width: width, font_scale: scale, workspaces: count,
            icons: icons ? "yaru" : "text-fallback", status_items: members, panel_window_height: window.height,
            exclusive_zone: window.exclusiveZone, capsules: { left: capsules[0], workspaces: capsules[1], status: capsules[2] },
            status_columns: findChild(layer, "panelStatusStrip").columns, workspace_columns: findChild(layer, "panelWorkspaceStrip").columns,
            menu_anchor: action === "menu" ? { x: menu.anchor.rect.x, y: menu.anchor.rect.y } : null
        }, extra)));
        mouseMove(screen, 5, 250);
        panel.release();
        panel.destroy();
        wait(50);
    }

    // Unavailable services, as on this machine: the scenes are about layout.
    function initTestCase() {
        Pipewire.ready = false;
        Pipewire.defaultAudioSink = null;
        Networking.backend = NetworkBackendType.None;
        Networking.connectivity = NetworkConnectivity.Unknown;
        Networking.devices = null;
    }

    function cleanupTestCase() {
        StubDesktop.screenWidth = 1280;
        Quickshell.iconMap = Data.iconMap;
    }

    function test_1_narrow_worst_cases() {
        scene("800-1x-10ws-text-2items", 800, 1, 10, false, 2, "");
        scene("800-1.5x-10ws-text-2items", 800, 1.5, 10, false, 2, "");
        scene("800-1.5x-9ws-icons", 800, 1.5, 9, true, 0, "");
        scene("1024-1.5x-10ws-text-2items", 1024, 1.5, 10, false, 2, "");
        scene("1024-1x-9ws-icons", 1024, 1, 9, true, 0, "");
    }

    function test_2_menu_from_wrapped_bar() {
        scene("menu-800-1x-10ws-text-2items", 800, 1, 10, false, 2, "menu");
    }

    function test_3_tooltips() {
        scene("tooltip-volume-1280", 1280, 1, 4, true, 0, "tooltip");
        scene("tooltip-long-800", 800, 1, 4, true, 0, "long-tooltip");
    }
}
