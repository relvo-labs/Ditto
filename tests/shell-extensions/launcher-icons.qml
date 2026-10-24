//@ pragma IconTheme DittoLauncherTest
import QtQuick
import Quickshell
import "jelly"

// #188 with real Quickshell (offscreen): both launchers, staged by
// stage-launcher.py, resolve icons through the real Quickshell.iconPath and
// image://icon provider. DittoLauncherTest is a fixture theme in the evidence
// directory; icon-search-paths.cpp gives offscreen Qt the XDG search paths.
// Rows: theme name, absolute PNG path, unknown theme name, undecodable file,
// no icon. Each icon must be requested at ceil(display x device pixel ratio).
ShellRoot {
    id: root
    readonly property string stagedDir: Quickshell.env("DITTO_TEST_LAUNCHER_DIR")
    readonly property string rasterFile: Quickshell.env("DITTO_TEST_RASTER_FILE")
    readonly property string corruptFile: Quickshell.env("DITTO_TEST_CORRUPT_FILE")
    // Names sort in this order, so the grid's alphabetical list keeps it.
    readonly property var apps: [
        { app_id: "theme", name: "A theme icon", icon: "ditto-launcher-raster", categories: [] },
        { app_id: "absolute", name: "B absolute PNG", icon: rasterFile, categories: [] },
        { app_id: "missing", name: "C missing name", icon: "ditto-launcher-no-such-icon", categories: [] },
        { app_id: "corrupt", name: "D load error", icon: corruptFile, categories: [] },
        { app_id: "none", name: "E no icon", icon: "", categories: [] }
    ]
    // Expected source, status (Image.Null 0 / Ready 1 / Error 3) and fallback.
    readonly property var expected: ({
        theme: { source: "image://icon/ditto-launcher-raster", status: 1, fallback: false },
        absolute: { source: "file://" + rasterFile, status: 1, fallback: false },
        missing: { source: "", status: 0, fallback: true },
        corrupt: { source: "file://" + corruptFile, status: 3, fallback: true },
        none: { source: "", status: 0, fallback: true }
    })
    readonly property var cases: [
        { provider: "grid", file: "LauncherGrid.qml", icon: "launcherGridIcon", fallback: "launcherGridIconFallback", display: 48 },
        { provider: "search", file: "LauncherSearch.qml", icon: "launcherSearchIcon", fallback: "launcherSearchIconFallback", display: 24 }
    ]
    property int caseIndex: 0
    property var launcher: null
    property int waited: 0
    property int failures: 0
    Tokens { id: tokens; readsSystemPreference: false }
    QtObject {
        id: client
        function t(source) { return source; }
        function key(source, args) { return source; }
        function capability(name, args, done, fail) {
            if (name === "desktop.launcher.list_apps") done({ apps: root.apps });
            else fail({ name: "unsupported" });
        }
        function launchApp(id, done, fail) {}
    }
    function collect(item, name, out) {
        if (!item) return;
        if (item.objectName === name) out.push(item);
        for (const child of item.children || []) collect(child, name, out);
    }
    function fail(message) {
        failures += 1;
        console.log("REAL_LAUNCHER_ICONS_FAILED " + message);
    }
    function start() {
        const spec = cases[caseIndex];
        const component = Qt.createComponent("file://" + stagedDir + "/" + spec.file);
        if (component.status !== Component.Ready) {
            fail(spec.provider + " " + component.errorString());
            return false;
        }
        launcher = component.createObject(root, { client: client, tokens: tokens, shown: true });
        launcher.open();
        if (spec.provider === "search") launcher.results = apps;
        waited = 0;
        return true;
    }
    function check() {
        const spec = cases[caseIndex];
        const icons = [];
        collect(launcher.stagedSurface.contentItem, spec.icon, icons);
        if (icons.length < apps.length || icons.some(icon => icon.status === Image.Loading)) return false;
        let checks = 0;
        for (const icon of icons) {
            // icon → icon tile → delegate (grid tile or search row)
            const app = icon.parent.parent.modelData;
            const want = expected[app.app_id];
            const fallbacks = [];
            collect(icon.parent, spec.fallback, fallbacks);
            const ratio = icon.Screen.devicePixelRatio;
            const device = Math.ceil(spec.display * ratio);
            const got = { app: app.app_id, source: String(icon.source), status: icon.status,
                fallback: fallbacks.length === 1 && fallbacks[0].visible, image_visible: icon.visible,
                source_size: [icon.sourceSize.width, icon.sourceSize.height], ratio: ratio };
            console.log("REAL_LAUNCHER_ICON " + spec.provider + " " + JSON.stringify(got));
            if (got.source !== want.source || got.status !== want.status || got.fallback !== want.fallback
                    || got.image_visible === want.fallback || got.source_size[0] !== device || got.source_size[1] !== device)
                fail(spec.provider + " " + JSON.stringify({ got: got, want: want, device_size: device }));
            checks += 1;
        }
        // The lookup itself: a theme name resolves, an unknown name does not.
        if (Quickshell.iconPath("ditto-launcher-raster", true) !== "image://icon/ditto-launcher-raster"
                || Quickshell.iconPath("ditto-launcher-no-such-icon", true) !== "")
            fail("Quickshell.iconPath did not use the fixture theme");
        checks += 1;
        if (failures === 0)
            console.log("REAL_LAUNCHER_ICONS_READY " + spec.provider + " ratio=" + icons[0].Screen.devicePixelRatio + " checks=" + checks);
        return true;
    }
    Timer {
        interval: 50
        repeat: true
        running: true
        onTriggered: {
            try {
                if (root.launcher === null) {
                    if (!root.start()) { stop(); Qt.quit(); }
                    return;
                }
                root.waited += interval;
                if (!root.check()) {
                    if (root.waited > 5000) { root.fail("icons did not settle"); stop(); Qt.quit(); }
                    return;
                }
                root.launcher.release();
                root.launcher.destroy();
                root.launcher = null;
                root.caseIndex += 1;
                if (root.caseIndex >= root.cases.length) {
                    stop();
                    console.log("REAL_LAUNCHER_ICONS_DONE failures=" + root.failures);
                    Qt.quit();
                }
            } catch (error) {
                root.fail("exception " + error);
                stop();
                Qt.quit();
            }
        }
    }
}
