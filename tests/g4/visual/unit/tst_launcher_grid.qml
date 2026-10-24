import QtQuick
import QtTest
import Quickshell
import DittoStub
import "../../../../shell/jelly" as Jelly
import "../.staged/i18n-data.js" as Catalogue

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
        property bool failLaunch: false
        // The Shell's language; t() reads the real runtime catalogues
        // (shell/i18n/ditto_*.json, staged by capture/prepare.py).
        property string language: "zh-TW"
        function t(text) {
            const hit = language === "en" ? Catalogue.en[text] : undefined;
            return hit !== undefined && hit !== "" ? hit : text;
        }
        function key(text, args) { return text; }
        function capability(method, args, ok, fail) {
            pending = pending.concat([{ method: method, args: args, ok: ok, fail: fail }]);
        }
        function launchApp(id, ok, fail) {
            launched = launched.concat([id]);
            if (failLaunch) fail({ name: "spawn_failed" });
        }
    }
    // #189 reference rendering: the same string and font as plain text.
    Text { id: plainReference; visible: false; textFormat: Text.PlainText }
    function init() {
        StubDesktop.layer = desktop;
        StubDesktop.screenWidth = 1280; StubDesktop.screenHeight = 800;
        Quickshell.iconMap = ({ fixture: Qt.resolvedUrl("../fixtures/test-icon.svg"),
            broken: Qt.resolvedUrl("../fixtures/missing-icon.svg") });
        client.pending = []; client.launched = []; client.failLaunch = false; client.language = "zh-TW";
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
        // #187: Left edits the text until the caret reaches the start.
        query().cursorPosition = 0;
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
        // #188: decoded at device pixels (display size x device pixel ratio).
        const device = Math.ceil(48 * ready.Screen.devicePixelRatio);
        compare(ready.sourceSize, Qt.size(device, device));
    }
    function test_absolute_raster_png_and_corrupt_file() {
        // #188: an absolute-path raster PNG loads directly; a file that is
        // there but cannot be decoded falls back to the letter.
        ignoreWarning(/QML (QQuick)?Image.*corrupt-icon\.png/);
        const raster = String(Qt.resolvedUrl("../fixtures/raster-icon-256.png")).replace("file://", "");
        const corrupt = String(Qt.resolvedUrl("../fixtures/corrupt-icon.png")).replace("file://", "");
        search("png").ok({ apps: [
            { app_id: "raster", name: "Raster", icon: raster, categories: [] },
            { app_id: "corrupt", name: "Corrupt", icon: corrupt, categories: [] }
        ] });
        const grid = findChild(desktop, "launcherGridApps");
        tryVerify(() => grid.itemAtIndex(1) !== null);
        const ready = findChild(grid.itemAtIndex(0), "launcherGridIcon");
        compare(String(ready.source), "file://" + raster);
        tryCompare(ready, "status", Image.Ready);
        verify(!findChild(grid.itemAtIndex(0), "launcherGridIconFallback").visible);
        const broken = findChild(grid.itemAtIndex(1), "launcherGridIcon");
        compare(String(broken.source), "file://" + corrupt);
        tryCompare(broken, "status", Image.Error);
        verify(!broken.visible);
        const fallback = findChild(grid.itemAtIndex(1), "launcherGridIconFallback");
        verify(fallback.visible);
        compare(fallback.text, "C");
    }

    // ---- #189: names are plain text ------------------------------------
    // Tag-like strings, ampersands and entities, quotes, CJK, a line break.
    function test_names_render_as_plain_text_data() {
        return [
            { tag: "bold-cjk", name: "<b>粗體</b>應用" },
            { tag: "italic-font-amp", name: "<i>Italic</i> & <font color=\"red\">Red</font>" },
            { tag: "link", name: "<a href=\"https://example.invalid\">連結</a>" },
            { tag: "line-break", name: "Two<br>lines" },
            { tag: "ampersand", name: "Tom & Jerry" },
            { tag: "entity", name: "AT&amp;T &lt;x&gt;" },
            { tag: "quotes", name: "\"引號\" 'single' 「括號」" },
            { tag: "cjk", name: "中文應用程式" }
        ];
    }
    function textShowing(root, text) {
        // Any Text that displays this string, found without relying on objectName.
        if (!root) return null;
        if (root.text === text && root.textFormat !== undefined && root.font !== undefined) return root;
        for (const child of root.children || []) {
            const found = textShowing(child, text);
            if (found) return found;
        }
        return null;
    }
    function verifyPlain(label, text, what) {
        verify(label !== null, what + " shows the string");
        plainReference.font = label.font;
        plainReference.text = text;
        // Rendered as rich text, tags vanish, entities collapse and <br> adds a line.
        compare(Math.round(label.implicitWidth), Math.round(plainReference.implicitWidth), what + " width");
        compare(Math.round(label.implicitHeight), Math.round(plainReference.implicitHeight), what + " height");
        // Names without markup render the same either way; the format must still be explicit.
        compare(label.textFormat, Text.PlainText, what + " is plain text");
    }
    function test_names_render_as_plain_text(row) {
        const app = { app_id: "n", name: row.name, icon: "", categories: [] };
        search("name").ok({ apps: [app] });
        const grid = findChild(desktop, "launcherGridApps");
        tryVerify(() => grid.itemAtIndex(0) !== null);
        verifyPlain(textShowing(grid.itemAtIndex(0), row.name), row.name, "grid tile name");
        const letter = findChild(grid.itemAtIndex(0), "launcherGridIconFallback");
        compare(letter.text, row.name.substring(0, 1));
        compare(letter.textFormat, Text.PlainText, "grid fallback letter is plain text");
        // The launch error carries the name, in both languages.
        client.failLaunch = true;
        for (const language of ["zh-TW", "en"]) {
            client.language = language;
            keyClick(Qt.Key_Return);
            const expected = (language === "en" ? "Could not start “%1”" : "無法啟動「%1」").arg(row.name);
            compare(launcher.status, expected);
            waitForRendering(desktop);
            verifyPlain(textShowing(desktop, expected), expected, "grid launch error (" + language + ")");
        }
        // Launcher B: result row, fallback letter and launch error.
        launcher.release();
        const search_ = makeSearchLauncher();
        search_.results = [app];
        tryVerify(() => textShowing(desktop, row.name) !== null);
        verifyPlain(textShowing(desktop, row.name), row.name, "search result name");
        compare(findChild(desktop, "launcherSearchIconFallback").textFormat, Text.PlainText,
            "search fallback letter is plain text");
        for (const language of ["zh-TW", "en"]) {
            client.language = language;
            search_.launch(app);
            const expected = (language === "en" ? "Could not start “%1”" : "無法啟動「%1」").arg(row.name);
            compare(search_.status, expected);
            waitForRendering(desktop);
            verifyPlain(textShowing(desktop, expected), expected, "search launch error (" + language + ")");
        }
        search_.release(); search_.destroy();
    }
    function makeSearchLauncher() {
        const component = Qt.createComponent(Qt.resolvedUrl("../.staged/providers/LauncherSearch.qml"));
        compare(component.status, Component.Ready, component.errorString());
        const created = component.createObject(testCase, { client: client, tokens: tokens, shown: true });
        created.open();
        return created;
    }

    // ---- #187: Left/Right edit text first, then move the grid ----------
    // cursor: caret before the key; start: grid selection before the key.
    // Expected: target (provider decision), caret, selected text, grid index.
    function test_left_right_keys_data() {
        const L = Qt.Key_Left, R = Qt.Key_Right, none = Qt.NoModifier, S = Qt.ShiftModifier;
        return [
            { tag: "left at start moves grid", text: "ab", cursor: 0, start: 1, key: L, mods: none, target: "grid", caret: 0, selected: "", index: 0 },
            { tag: "left in middle moves caret", text: "ab", cursor: 1, start: 1, key: L, mods: none, target: "field", caret: 0, selected: "", index: 1 },
            { tag: "left at end moves caret", text: "ab", cursor: 2, start: 1, key: L, mods: none, target: "field", caret: 1, selected: "", index: 1 },
            { tag: "right at start moves caret", text: "ab", cursor: 0, start: 0, key: R, mods: none, target: "field", caret: 1, selected: "", index: 0 },
            { tag: "right in middle moves caret", text: "ab", cursor: 1, start: 0, key: R, mods: none, target: "field", caret: 2, selected: "", index: 0 },
            { tag: "right at end moves grid", text: "ab", cursor: 2, start: 0, key: R, mods: none, target: "grid", caret: 2, selected: "", index: 1 },
            { tag: "shift+left at end selects", text: "ab", cursor: 2, start: 1, key: L, mods: S, target: "field", caret: 1, selected: "b", index: 1 },
            { tag: "shift+right at start selects", text: "ab", cursor: 0, start: 0, key: R, mods: S, target: "field", caret: 1, selected: "a", index: 0 },
            { tag: "shift+left at start stays in field", text: "ab", cursor: 0, start: 1, key: L, mods: S, target: "field", caret: 0, selected: "", index: 1 },
            { tag: "shift+right at end stays in field", text: "ab", cursor: 2, start: 0, key: R, mods: S, target: "field", caret: 2, selected: "", index: 0 },
            { tag: "ctrl+left at end moves by word", text: "ab", cursor: 2, start: 1, key: L, mods: Qt.ControlModifier, target: "field", caret: 0, selected: "", index: 1 },
            { tag: "selection collapses before grid moves", text: "ab", cursor: 2, selectAll: true, start: 0, key: R, mods: none, target: "field", caret: 2, selected: "", index: 0 },
            { tag: "empty query right browses", text: "", cursor: 0, start: 0, key: R, mods: none, target: "grid", caret: 0, selected: "", index: 1 },
            { tag: "empty query left browses", text: "", cursor: 0, start: 1, key: L, mods: none, target: "grid", caret: 0, selected: "", index: 0 },
            { tag: "no results, right at end", text: "zz", cursor: 2, start: -1, noResults: true, key: R, mods: none, target: "grid", caret: 2, selected: "", index: -1 },
            { tag: "no results, left in middle", text: "zz", cursor: 1, start: -1, noResults: true, key: L, mods: none, target: "field", caret: 0, selected: "", index: -1 },
            // Pre-edit text cannot be produced by QtTest key events: this row
            // checks the decision only, the key delivery is not exercised.
            { tag: "composing goes to the input method", text: "ab", cursor: 2, start: 0, composing: true, key: R, mods: none, target: "ime" }
        ];
    }
    function test_left_right_keys(row) {
        const field = query();
        const grid = findChild(desktop, "launcherGridApps");
        if (row.text.length > 0) search(row.text).ok({ apps: row.noResults ? [] : apps });
        compare(launcher.visibleApps.length, row.noResults ? 0 : 2);
        if (!row.composing) {
            grid.currentIndex = row.start;
            field.cursorPosition = row.cursor;
            if (row.selectAll) field.selectAll();
            verify(field.activeFocus);
            // A real key event through the window to the focused search field.
            keyClick(row.key, row.mods);
            compare(field.text, row.text, "query text unchanged");
            compare(field.cursorPosition, row.caret, "caret");
            compare(field.selectedText, row.selected, "selection");
            compare(grid.currentIndex, row.index, "grid selection");
            verify(field.activeFocus, "focus stays in the search field");
        }
        compare(launcher.arrowTarget(row.key, row.mods, row.composing === true, row.cursor, row.text.length,
            row.selectAll === true), row.target, "decision");
    }
    function test_up_down_enter_escape_keep_working_with_caret_in_middle() {
        search("ab").ok({ apps: apps });
        const field = query();
        field.cursorPosition = 1;
        keyClick(Qt.Key_Down);
        keyClick(Qt.Key_Return);
        compare(client.launched, ["a"], "Down stops at the last result; Enter launches it");
        keyClick(Qt.Key_Escape);
        compare(field.text, "");
        verify(launcher.isOpen);
    }

    // ---- #187: selection changes are announced -------------------------
    function test_keyboard_selection_is_announced() {
        search("editor").ok({ apps: apps });
        compare(launcher.selectionAnnouncement, "");
        keyClick(Qt.Key_Right);
        compare(launcher.selectionAnnouncement, "Alpha browser，第 2 項，共 2 項");
        client.language = "en";
        query().cursorPosition = 0;
        keyClick(Qt.Key_Left);
        compare(launcher.selectionAnnouncement, "Zulu editor, 1 of 2");
        // The caret moves inside the text: not a selection change.
        query().cursorPosition = 3;
        keyClick(Qt.Key_Left);
        compare(launcher.selectionAnnouncement, "Zulu editor, 1 of 2");
        compare(query().cursorPosition, 2);
        // A name with placeholders or markup is announced as written.
        search("odd").ok({ apps: [{ app_id: "p", name: "<b>%1 & %2</b>", icon: "", categories: [] }, apps[1]] });
        keyClick(Qt.Key_Right);
        compare(launcher.selectionAnnouncement, "Alpha browser, 2 of 2");
        query().cursorPosition = 0;
        keyClick(Qt.Key_Left);
        compare(launcher.selectionAnnouncement, "<b>%1 & %2</b>, 1 of 2");
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
        const device = Math.ceil(24 * icon.Screen.devicePixelRatio);
        compare(icon.sourceSize, Qt.size(device, device));
        compare(searchLauncher.iconSource("/tmp/app.svg"), launcher.iconSource("/tmp/app.svg"));
        verify(searchLauncher.iconFallback("file:///missing", Image.Error));
        searchLauncher.results = [apps[1]];
        tryVerify(() => findChild(desktop, "launcherSearchIconFallback").visible);
        searchLauncher.release(); searchLauncher.destroy();
    }
}
