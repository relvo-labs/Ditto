import QtQuick
import QtTest
import Quickshell
import DittoStub
import "../../../../shell/jelly" as Jelly

// DES-02 / AT-01: real provider, layer-shell removed by stage-providers.mjs.
// Replies are deliberately held so success/error races are deterministic.
TestCase {
    id: testCase
    name: "LauncherGridSearch"
    width: 1280; height: 800
    visible: true
    when: windowShown
    Item { id: desktop; width: 1280; height: 800 }
    Jelly.Tokens { id: tokens }
    property var launcher: null
    readonly property var apps: [
        { app_id: "z", name: "Zulu editor", icon: "fixture", categories: ["Development"] },
        { app_id: "a", name: "Alpha browser", icon: "", categories: ["Network"] }
    ]
    QtObject {
        id: client
        property var pending: []
        property var launched: []
        function t(text) { return text; }
        function key(text, args) { return text; }
        function capability(method, args, ok, fail) {
            pending = pending.concat([{ method: method, args: args, ok: ok, fail: fail }]);
        }
        function launchApp(id, ok, fail) { launched = launched.concat([id]); }
    }
    function init() {
        StubDesktop.layer = desktop;
        StubDesktop.screenWidth = 1280; StubDesktop.screenHeight = 800;
        Quickshell.iconMap = ({ fixture: Qt.resolvedUrl("../fixtures/test-icon.svg"),
            broken: Qt.resolvedUrl("../fixtures/missing-icon.svg") });
        client.pending = []; client.launched = [];
        const component = Qt.createComponent(Qt.resolvedUrl("../.staged/providers/LauncherGrid.qml"));
        compare(component.status, Component.Ready, component.errorString());
        launcher = component.createObject(testCase, { client: client, tokens: tokens, shown: true });
        launcher.open();
        compare(client.pending[0].method, "desktop.launcher.list_apps");
        client.pending[0].ok({ apps: apps });
        wait(30);
    }
    function cleanup() {
        if (launcher) { launcher.release(); launcher.destroy(); launcher = null; }
        wait(0);
    }
    function query() {
        const field = findChild(desktop, "launcherGridQuery");
        verify(field !== null, "grid launcher has a search field");
        return field;
    }
    function search(text) {
        query().text = text;
        return client.pending[client.pending.length - 1];
    }
    function test_query_calls_core_across_categories() {
        verify(query().activeFocus, "search focused on open");
        launcher.categoryIndex = 1;
        for (const key of [Qt.Key_E, Qt.Key_D, Qt.Key_I, Qt.Key_T, Qt.Key_O, Qt.Key_R]) keyClick(key);
        const request = client.pending[client.pending.length - 1];
        compare(request.method, "desktop.launcher.search");
        compare(request.args, { query: "editor", limit: 200 });
        compare(launcher.categories, [""]);
        request.ok({ apps: apps });
        compare(launcher.visibleApps, apps, "Core relevance order is retained");
    }
    function test_stale_success_and_error_do_not_replace_new_query() {
        const old = search("old"), current = search("new");
        current.ok({ apps: [apps[1]] });
        old.ok({ apps: [apps[0]] });
        old.fail({ name: "unavailable" });
        compare(launcher.visibleApps, [apps[1]]);
        compare(launcher.status, "");
    }
    function test_escape_clears_then_closes_and_invalidates_reply() {
        const request = search("editor");
        keyClick(Qt.Key_Escape);
        compare(query().text, "");
        verify(launcher.isOpen);
        request.ok({ apps: [apps[0]] });
        compare(launcher.visibleApps.length, 2);
        keyClick(Qt.Key_Escape);
        verify(!launcher.isOpen);
    }
    function test_enter_launches_first_result() {
        search("editor").ok({ apps: apps });
        keyClick(Qt.Key_Return);
        compare(client.launched, ["z"]);
    }
    function test_arrows_move_selection_without_losing_query_focus() {
        search("editor").ok({ apps: apps });
        keyClick(Qt.Key_Right);
        keyClick(Qt.Key_Enter);
        compare(client.launched, ["a"]);
        keyClick(Qt.Key_Left);
        keyClick(Qt.Key_Return);
        compare(client.launched, ["a", "z"]);
        verify(query().activeFocus);
        const many = [];
        for (let i = 0; i < 20; ++i) many.push(Object.assign({}, apps[0], { app_id: String(i) }));
        search("many").ok({ apps: many });
        const grid = findChild(desktop, "launcherGridApps");
        keyClick(Qt.Key_Down);
        compare(grid.currentIndex, Math.floor(grid.width / grid.cellWidth));
        keyClick(Qt.Key_Up);
        compare(grid.currentIndex, 0);
    }
    function test_pending_empty_and_error_cannot_launch_old_apps() {
        const request = search("missing");
        keyClick(Qt.Key_Return);
        compare(client.launched, []);
        request.ok({ apps: [] });
        compare(launcher.status, "沒有符合的應用程式");
        search("failed").fail({ name: "unavailable" });
        compare(launcher.visibleApps, []);
        verify(launcher.status.indexOf("搜尋暫不可用") >= 0);
        keyClick(Qt.Key_Return);
        compare(client.launched, []);
    }
    function test_list_reply_cannot_override_search_status() {
        const current = search("missing");
        current.ok({ apps: [] });
        client.pending[0].ok({ apps: apps });
        compare(launcher.visibleApps, []);
        compare(launcher.status, "沒有符合的應用程式");
    }
    function test_close_reopen_rejects_old_reply() {
        const old = search("old");
        launcher.close(); launcher.open();
        const list = client.pending[client.pending.length - 1];
        list.ok({ apps: [apps[1]] });
        old.ok({ apps: [apps[0]] });
        compare(launcher.visibleApps, [apps[1]]);
        compare(launcher.status, "");
    }
    function test_icon_source_and_fallback_decision() {
        verify(typeof launcher.iconSource === "function");
        compare(String(launcher.iconSource("fixture")), String(Quickshell.iconMap.fixture));
        compare(launcher.iconSource(""), "");
        compare(launcher.iconSource(null), "");
        compare(launcher.iconSource("unknown"), "");
        compare(launcher.iconSource("/tmp/app.svg"), "file:///tmp/app.svg");
        verify(launcher.iconFallback("", Image.Null));
        verify(launcher.iconFallback("file:///missing", Image.Error));
        verify(launcher.iconFallback("file:///pending", Image.Loading));
        verify(!launcher.iconFallback("file:///ready", Image.Ready));
    }
    function test_rendered_icon_ready_missing_and_load_error() {
        // The failed load must still display a letter, even for a resolved URL.
        ignoreWarning(/QML (QQuick)?Image: Cannot open: .*missing-icon.svg/);
        search("icons").ok({ apps: apps.concat([
            { app_id: "broken", name: "Broken", icon: "broken", categories: [] }
        ]) });
        const grid = findChild(desktop, "launcherGridApps");
        verify(grid !== null);
        tryVerify(() => grid.itemAtIndex(2) !== null);
        const ready = findChild(grid.itemAtIndex(0), "launcherGridIcon");
        tryCompare(ready, "status", Image.Ready);
        verify(!findChild(grid.itemAtIndex(0), "launcherGridIconFallback").visible);
        verify(findChild(grid.itemAtIndex(1), "launcherGridIconFallback").visible);
        const broken = findChild(grid.itemAtIndex(2), "launcherGridIcon");
        tryCompare(broken, "status", Image.Error);
        verify(findChild(grid.itemAtIndex(2), "launcherGridIconFallback").visible);
        compare(ready.sourceSize.width, 48);
    }
    function test_whitespace_and_normal_category_keyboard() {
        const calls = client.pending.length;
        search("   ");
        compare(client.pending.length, calls, "whitespace uses the indexed app list");
        keyClick(Qt.Key_Escape);
        verify(launcher.isOpen);
        keyClick(Qt.Key_Return);
        compare(client.launched, ["a"], "normal list selects the first app alphabetically");
        keyClick(Qt.Key_PageDown);
        compare(launcher.visibleApps, [apps[0]]);
        keyClick(Qt.Key_Return);
        compare(client.launched, ["a", "z"]);
    }
    function test_search_launcher_uses_same_icon_rules() {
        launcher.release();
        const component = Qt.createComponent(Qt.resolvedUrl("../.staged/providers/LauncherSearch.qml"));
        compare(component.status, Component.Ready, component.errorString());
        const searchLauncher = component.createObject(testCase, { client: client, tokens: tokens, shown: true });
        searchLauncher.open();
        searchLauncher.results = apps;
        tryVerify(() => findChild(desktop, "launcherSearchIcon") !== null);
        const icon = findChild(desktop, "launcherSearchIcon");
        tryCompare(icon, "status", Image.Ready);
        compare(icon.sourceSize.width, 24);
        compare(searchLauncher.iconSource("/tmp/app.svg"), launcher.iconSource("/tmp/app.svg"));
        verify(searchLauncher.iconFallback("file:///missing", Image.Error));
        searchLauncher.results = [apps[1]];
        tryVerify(() => findChild(desktop, "launcherSearchIconFallback").visible);
        searchLauncher.release(); searchLauncher.destroy();
    }
}
