import QtQuick
import QtQuick.Window
import QtTest
import Quickshell
import DittoStub
import "../../../../shell/jelly" as Jelly

// Labelled launcher fixtures, not a live Core index. Both scale factors use
// the actual provider and scalable icon source; only layer-shell is removed.
TestCase {
    id: testCase
    name: "CaptureLauncherGrid"
    width: 1280; height: 800
    visible: true
    when: windowShown
    readonly property real ratio: Screen.devicePixelRatio
    readonly property string outDir: Qt.resolvedUrl("../.staged/out/").toString().replace("file://", "")
    Jelly.Tokens { id: tokens; appearance: ({ theme: "soft-jelly-light", tokens: {}, locale: "zh-TW" }) }
    Rectangle { id: scene; width: 1280; height: 800; color: tokens.background }
    readonly property var apps: [
        { app_id: "editor", name: "Fixture Editor", icon: "fixture", categories: ["Development"] },
        { app_id: "browser", name: "Fixture Browser", icon: "fixture", categories: ["Network"] },
        { app_id: "notes", name: "Fixture Notes (no icon)", icon: "", categories: ["Utility"] }
    ]
    QtObject {
        id: client
        function t(text) { return text; }
        function key(text, args) {
            const labels = { "category.Development": "開發", "category.Network": "網路", "category.Utility": "工具" };
            return labels[text] || text;
        }
        function capability(method, args, ok, fail) {
            if (method === "desktop.launcher.list_apps") ok({ apps: testCase.apps });
            else if (method === "desktop.launcher.search") {
                // Fixed Core reply fixtures retain this relevance order.
                ok({ apps: args.query === "notes" ? [testCase.apps[2]] : [testCase.apps[0], testCase.apps[2]] });
            } else fail({ name: "unsupported" });
        }
    }
    function test_scenes() {
        failOnWarning(/./);
        StubDesktop.layer = scene;
        StubDesktop.screenWidth = 1280; StubDesktop.screenHeight = 800;
        Quickshell.iconMap = ({ fixture: Qt.resolvedUrl("../fixtures/test-icon.svg") });
        const component = Qt.createComponent(Qt.resolvedUrl("../.staged/providers/LauncherGrid.qml"));
        compare(component.status, Component.Ready, component.errorString());
        const launcher = component.createObject(testCase, { tokens: tokens, client: client, shown: true });
        launcher.open();
        const field = findChild(scene, "launcherGridQuery");
        const grid = findChild(scene, "launcherGridApps");
        for (const variant of ["normal", "search", "no-icon"]) {
            field.text = variant === "normal" ? "" : variant === "search" ? "edit" : "notes";
            tryCompare(grid, "count", variant === "normal" ? 3 : variant === "search" ? 2 : 1);
            waitForRendering(scene);
            const tile = grid.itemAtIndex(0);
            const icon = findChild(tile, "launcherGridIcon");
            const fallback = findChild(tile, "launcherGridIconFallback");
            if (variant === "no-icon") verify(fallback.visible);
            else { tryCompare(icon, "status", Image.Ready); verify(!fallback.visible); }
            const filename = "launcher-grid-" + variant + "-" + ratio + "x.png";
            let image = null;
            scene.grabToImage(result => { image = result; });
            tryVerify(() => image !== null);
            verify(image.saveToFile(outDir + filename));
            console.log("LAUNCHER_META " + JSON.stringify({
                capture: filename, device_pixel_ratio: ratio, query: field.text,
                result_ids: launcher.visibleApps.map(app => app.app_id),
                categories: launcher.categories, source: String(icon.source),
                source_size: [icon.sourceSize.width, icon.sourceSize.height], fallback: fallback.visible
            }));
        }
        launcher.release(); launcher.destroy();
        wait(0);
    }
}
