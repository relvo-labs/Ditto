import QtQuick
import QtQuick.Window
import QtTest
import Quickshell
import DittoStub
import "../../../../shell/jelly" as Jelly

// Labelled launcher fixtures, not a live Core index. Both scale factors use
// the actual provider and scalable icon source; only layer-shell is removed.
// #188 adds an absolute-path raster PNG (grid and search launcher) and a file
// that exists but cannot be decoded; capture/check_launcher_icons.py compares
// the raster icon's device pixels with a direct raster of the same PNG.
TestCase {
    id: testCase
    name: "CaptureLauncherGrid"
    width: 1280; height: 800
    visible: true
    when: windowShown
    readonly property real ratio: Screen.devicePixelRatio
    readonly property string outDir: Qt.resolvedUrl("../.staged/out/").toString().replace("file://", "")
    readonly property string rasterFile: Qt.resolvedUrl("../fixtures/raster-icon-256.png").toString().replace("file://", "")
    readonly property string corruptFile: Qt.resolvedUrl("../fixtures/corrupt-icon.png").toString().replace("file://", "")
    Jelly.Tokens { id: tokens; appearance: ({ theme: "soft-jelly-light", tokens: {}, locale: "zh-TW" }) }
    Rectangle { id: scene; width: 1280; height: 800; color: tokens.background }
    readonly property var apps: [
        { app_id: "editor", name: "Fixture Editor", icon: "fixture", categories: ["Development"] },
        { app_id: "browser", name: "Fixture Browser", icon: "fixture", categories: ["Network"] },
        { app_id: "notes", name: "Fixture Notes (no icon)", icon: "", categories: ["Utility"] }
    ]
    readonly property var rasterApp: ({ app_id: "raster", name: "Fixture Raster (PNG path)", icon: rasterFile, categories: [] })
    readonly property var corruptApp: ({ app_id: "corrupt", name: "Fixture Corrupt (load error)", icon: corruptFile, categories: [] })
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
                const replies = { notes: [testCase.apps[2]], raster: [testCase.rasterApp], corrupt: [testCase.corruptApp] };
                ok({ apps: replies[args.query] || [testCase.apps[0], testCase.apps[2]] });
            } else fail({ name: "unsupported" });
        }
    }
    // `meta` is read after rendering, so the icon rectangle is the laid-out one.
    function save(filename, meta) {
        waitForRendering(scene);
        let image = null;
        scene.grabToImage(result => { image = result; });
        tryVerify(() => image !== null);
        verify(image.saveToFile(outDir + filename));
        console.log("LAUNCHER_META " + JSON.stringify(Object.assign({ capture: filename, device_pixel_ratio: ratio,
            capture_size: [Math.round(scene.width * ratio), Math.round(scene.height * ratio)] }, meta())));
    }
    function iconMeta(icon, fallback, display) {
        const at = icon.mapToItem(scene, 0, 0);
        return { source: String(icon.source), source_size: [icon.sourceSize.width, icon.sourceSize.height],
            display_size: display, icon_rect: [at.x, at.y, icon.width, icon.height],
            icon_status: icon.status, fallback: fallback.visible };
    }
    function test_scenes() {
        failOnWarning(/./);
        // The undecodable fixture is expected to warn once per load.
        ignoreWarning(/QML (QQuick)?Image.*corrupt-icon\.png/);
        StubDesktop.layer = scene;
        StubDesktop.screenWidth = 1280; StubDesktop.screenHeight = 800;
        Quickshell.iconMap = ({ fixture: Qt.resolvedUrl("../fixtures/test-icon.svg") });
        const component = Qt.createComponent(Qt.resolvedUrl("../.staged/providers/LauncherGrid.qml"));
        compare(component.status, Component.Ready, component.errorString());
        const launcher = component.createObject(testCase, { tokens: tokens, client: client, shown: true });
        launcher.open();
        const field = findChild(scene, "launcherGridQuery");
        const grid = findChild(scene, "launcherGridApps");
        const device = Math.ceil(48 * ratio);
        const sizeMismatches = [];
        for (const variant of ["normal", "search", "no-icon", "raster", "load-error"]) {
            field.text = { normal: "", search: "edit", "no-icon": "notes", raster: "raster", "load-error": "corrupt" }[variant];
            tryCompare(grid, "count", variant === "normal" ? 3 : variant === "search" ? 2 : 1);
            waitForRendering(scene);
            const tile = grid.itemAtIndex(0);
            const icon = findChild(tile, "launcherGridIcon");
            const fallback = findChild(tile, "launcherGridIconFallback");
            if (variant === "no-icon") verify(fallback.visible);
            else if (variant === "load-error") {
                tryCompare(icon, "status", Image.Error);
                verify(fallback.visible && !icon.visible);
            } else { tryCompare(icon, "status", Image.Ready); verify(!fallback.visible); }
            save("launcher-grid-" + variant + "-" + ratio + "x.png", () => Object.assign({
                provider: "grid", query: field.text,
                result_ids: launcher.visibleApps.map(app => app.app_id),
                categories: launcher.categories,
                icon_file: variant === "raster" ? rasterFile : null
            }, iconMeta(icon, fallback, 48)));
            // #188: the icon is decoded at device pixels, not at its display size.
            if (icon.sourceSize.width !== device || icon.sourceSize.height !== device)
                sizeMismatches.push(variant + ": " + icon.sourceSize + " != " + device);
        }
        launcher.release(); launcher.destroy();
        wait(0);

        // Launcher B: the same raster file in a 24 px result row.
        const searchComponent = Qt.createComponent(Qt.resolvedUrl("../.staged/providers/LauncherSearch.qml"));
        compare(searchComponent.status, Component.Ready, searchComponent.errorString());
        const searchLauncher = searchComponent.createObject(testCase, { tokens: tokens, client: client, shown: true });
        searchLauncher.open();
        searchLauncher.results = [rasterApp];
        tryVerify(() => findChild(scene, "launcherSearchIcon") !== null);
        const rowIcon = findChild(scene, "launcherSearchIcon");
        tryCompare(rowIcon, "status", Image.Ready);
        save("launcher-search-raster-" + ratio + "x.png", () => Object.assign({ provider: "search", query: "",
            result_ids: [rasterApp.app_id], icon_file: rasterFile },
            iconMeta(rowIcon, findChild(scene, "launcherSearchIconFallback"), 24)));
        const rowDevice = Math.ceil(24 * ratio);
        if (rowIcon.sourceSize.width !== rowDevice || rowIcon.sourceSize.height !== rowDevice)
            sizeMismatches.push("search raster: " + rowIcon.sourceSize + " != " + rowDevice);
        searchLauncher.release(); searchLauncher.destroy();
        wait(0);
        // Asserted after every scene is saved, so a failure still leaves
        // captures for check_launcher_icons.py.
        compare(sizeMismatches, []);
    }
}
