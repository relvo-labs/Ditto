import QtQuick
import QtTest
import Quickshell
import DittoStub
import "../../../../shell/jelly" as Jelly
import "../.staged/capture-data.js" as Data

// Native comparison capture for #65 (scene `g4-r1-default-desktop`), at
// 1280×800 and scale 1, rendered offscreen by the real Shell QML: the canvas
// (shell/jelly/Backdrop), the top panel and the Dock (the real providers,
// staged with only their layer-shell lines removed), and two blank material
// samples (shell/jelly/Material) where the reference has its two windows.
//
// Labelled test data: the workspace list (four, the first active), the Dock's
// pinned list (installed applications of this machine, see prepare.py), and,
// in the `dock-states` image only, two window records. The samples are not
// applications and carry no content. The clock is the real time of the run.
// No wallpaper, title, weather or assistant is drawn: those are pending
// (component-sheet.md). Development evidence, not a reference-machine capture.
TestCase {
    id: testCase
    name: "CaptureDefaultDesktop"
    width: 1280
    height: 800
    visible: true
    when: windowShown

    readonly property string outDir: Qt.resolvedUrl("../.staged/out/").toString().replace("file://", "")

    Item {
        id: screen
        width: 1280
        height: 800

        Jelly.Backdrop {
            id: backdrop
            anchors.fill: parent
            tokens: sceneTokens
            wallpaperSource: ""
        }

        Repeater {
            model: [
                { name: "back", x: 37, y: 63, width: 643, height: 455 },
                { name: "front", x: 77, y: 465, width: 535, height: 230 }
            ]

            Item {
                required property var modelData
                objectName: "materialSample_" + modelData.name
                x: modelData.x
                y: modelData.y
                width: modelData.width
                height: modelData.height

                Jelly.Material {
                    anchors.fill: parent
                    tokens: sceneTokens
                    radius: 16
                }

                Text {
                    x: 16
                    y: 12
                    text: "材質樣本（非應用視窗）· material sample, not an application"
                    color: sceneTokens.foregroundMuted
                    font.pixelSize: sceneTokens.fontSmall
                }
            }
        }

        Item {
            id: layer
            anchors.fill: parent
        }
    }

    Jelly.Tokens {
        id: sceneTokens
        appearance: ({ theme: "soft-jelly-light", tokens: {}, locale: "zh-TW" })
    }

    QtObject {
        id: client
        property bool online: true
        property string status: ""
        property var windows: []
        property var workspaces: [
            { id: "1", name: "1", active: true }, { id: "2", name: "2", active: false },
            { id: "3", name: "3", active: false }, { id: "4", name: "4", active: false }
        ]
        function t(text) { return text; }
        function key(text) { return text; }
        function errorText(error) { return "failed"; }
        function capabilityAvailable(id) { return id === "desktop.workspaces.activate"; }
        function activateWorkspace(id) {}
        function focusWindow(id) {}
        function launchApp(id) {}
        function capability(method, args, ok, fail) {
            if (method === "desktop.launcher.list_apps") ok({ apps: Data.apps });
            else if (fail) fail({ name: "unavailable", message: method });
        }
    }

    property var mounted: []

    function mount(file, config) {
        const component = Qt.createComponent(Qt.resolvedUrl("../.staged/providers/" + file));
        verify(component.status === Component.Ready, component.errorString());
        const incubator = component.incubateObject(testCase, {
            client: client, tokens: sceneTokens, config: config, entryId: file, slotName: "", shown: false
        });
        incubator.forceCompletion();
        const provider = incubator.object;
        provider.shown = true;
        mounted.push(provider);
        return provider;
    }

    function unmountAll() {
        for (const provider of mounted) {
            provider.release();
            provider.destroy();
        }
        mounted = [];
        wait(50);
    }

    function rect(item) {
        const p = item.mapToItem(screen, 0, 0);
        return { x: Math.round(p.x), y: Math.round(p.y), width: Math.round(item.width), height: Math.round(item.height) };
    }

    function render(mode, appearance, windows, focusApp) {
        sceneTokens.appearance = appearance;
        client.windows = windows;
        const dock = mount("DockPill.qml", { position: "bottom", pinned: Data.pinned });
        const panel = mount("PanelTop.qml", {});
        tryCompare(dock, "appsLoaded", true);
        const capsule = findChild(layer, "dockCapsule");
        tryVerify(() => capsule.width > capsule.height * 2, 3000, "dock laid out");
        // Every icon has loaded or failed (then the lettered tile shows).
        tryVerify(() => {
            for (const entry of dock.entries) {
                const icon = findChild(findChild(layer, "dockTile_" + entry.appId), "dockIcon");
                if (icon.status === Image.Loading) return false;
            }
            return true;
        }, 5000, "icons settled");
        if (focusApp) {
            findChild(layer, "dockTile_" + focusApp).forceActiveFocus();
        }
        waitForRendering(screen);
        const image = grabImage(screen);
        const path = outDir + mode + ".png";
        image.save(path);
        const icons = dock.entries.map(entry => {
            const icon = findChild(findChild(layer, "dockTile_" + entry.appId), "dockIcon");
            return { app_id: entry.appId, icon_status: icon.status === Image.Ready ? "ready" : "fallback",
                     source: String(icon.source) };
        });
        console.log("CAPTURE_META " + JSON.stringify({
            mode: mode, file: path, viewport: { width: 1280, height: 800, scale: 1 },
            renderer: screen.GraphicsInfo.api === GraphicsInfo.Software ? "software" : "hardware(" + screen.GraphicsInfo.api + ")",
            appearance: appearance, material_shadow_path: findChild(screen, "materialSample_back").children[0].shadowPath,
            fixture: { workspaces: client.workspaces.length, windows: windows, pinned: Data.pinned, focus_tile: focusApp || null },
            geometry: { dock_capsule: rect(capsule), dock_window: rect(capsule.parent), panel_window: rect(findChild(layer, "stubPanelWindow")),
                        sample_back: rect(findChild(screen, "materialSample_back")), sample_front: rect(findChild(screen, "materialSample_front")) },
            dock_icons: icons, wallpaper_shown: backdrop.wallpaperShown
        }));
        unmountAll();
        return path;
    }

    function light(extra) {
        return Object.assign({ theme: "soft-jelly-light", tokens: {}, locale: "zh-TW" }, extra || {});
    }

    function test_1_normal() {
        render("normal", light(), [], null);
    }

    function test_2_reduced_transparency() {
        render("reduced-transparency", light({ reduced_transparency: true }), [], null);
    }

    function test_3_low_power() {
        render("low-power", light({ low_power_style: true }), [], null);
    }

    /// Fixture windows (labelled): the first pinned app in use, the third
    /// running; keyboard focus on the second tile.
    function test_4_dock_states() {
        const windows = [
            { id: "fixture-1", app_id: Data.pinned[0], title: "fixture", focused: true },
            { id: "fixture-2", app_id: Data.pinned[2], title: "fixture", focused: false }
        ];
        render("dock-states", light(), windows, Data.pinned[1]);
    }

    function initTestCase() {
        StubDesktop.layer = layer;
        StubDesktop.screenWidth = 1280;
        StubDesktop.screenHeight = 800;
        Quickshell.iconMap = Data.iconMap;
    }
}
