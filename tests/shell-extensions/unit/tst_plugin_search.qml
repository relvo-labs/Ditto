import QtQuick
import QtTest
import "../shell/ui" as Ui
import "../shell/jelly" as Jelly

TestCase {
    id: testCase
    name: "PluginSearch"
    when: windowShown
    visible: true
    width: 1000
    height: 760

    QtObject {
        id: translations
        property string language: "zh-TW"
        function has(key) { return false; }
        function slotName(slot) { return slot; }
        function localized(value) {
            if (value && typeof value === "object") return value[language] || value["zh-TW"] || value.en || "";
            return value ? String(value) : "";
        }
    }
    Jelly.Tokens { id: tokens; readsSystemPreference: false }

    function summary() {
        return {package_id: "ditto.weather", version: "1.0.0", name: {"zh-TW": "天氣面板", en: "Weather Panel"},
            host_kind: "qml", source: "builtin", trust_level: "trusted", author: "Ditto", license: "MIT"};
    }
    function manifest() {
        return {description: {"zh-TW": "每日溫度與預報", en: "Daily forecast"}, permissions: [], slots: []};
    }
    function entries() {
        return [{entry_id: "forecast-morning", package: "ditto.weather", name: "早晨摘要", host: "qml", disabled: false,
            started_reason: "profile", trust_note_key: "trust.same_host_no_isolation.qml", state: {kind: "active"}}];
    }
    function test_matches_data() {
        return [
            {tag: "name", query: "天氣", expected: true},
            {tag: "id", query: "ditto.weather", expected: true},
            {tag: "description", query: "溫度", expected: true},
            {tag: "entry-id", query: "forecast-morning", expected: true},
            {tag: "entry-name", query: "早晨", expected: true},
            {tag: "case", query: "DITTO.WEATHER", expected: true},
            {tag: "entry-case", query: "FORECAST-MORNING", expected: true},
            {tag: "no-result", query: "calendar", expected: false},
            {tag: "empty", query: "", expected: true},
            {tag: "whitespace", query: "  ", expected: true},
            {tag: "trimmed-cjk", query: " 預報 ", expected: true}
        ];
    }
    function test_matches(data) {
        compare(Ui.PluginFilter.matches(summary(), manifest(), entries(), data.query,
            value => translations.localized(value)), data.expected);
    }
    function test_localized_names_and_missing_details() {
        translations.language = "en";
        verify(Ui.PluginFilter.matches(summary(), manifest(), [], "wEaThEr pAnEl", value => translations.localized(value)));
        verify(Ui.PluginFilter.matches(summary(), manifest(), [], "DAILY", value => translations.localized(value)));
        verify(Ui.PluginFilter.matches(summary(), null, [], "ditto.weather", value => translations.localized(value)));
        verify(!Ui.PluginFilter.matches(summary(), null, [], "forecast", value => translations.localized(value)));
        verify(Ui.PluginFilter.matches({package_id: "bare"}, null, [{package: "bare", entry_id: "bare-entry"}], "entry", value => translations.localized(value)));
        verify(!Ui.PluginFilter.matches(summary(), null, [{package: "other", entry_id: "unrelated"}], "unrelated", value => translations.localized(value)));
        translations.language = "zh-TW";
    }

    Component {
        id: clientFactory
        QtObject {
            property var tr: translations
            property var calls: []
            signal capabilitiesReloaded()
            signal panelsReported(var panels)
            signal profileChanged(var profile)
            signal jobUpdated(var job)
            signal changeUpdated(var change)
            function t(source) { return source; }
            function key(source, args) { return source; }
            function join(values) { return values.join(", "); }
            function capability(name, args, done, fail) {
                calls = calls.concat([name]);
                if (name === "desktop.plugins.list") done({packages: [], entries: []});
                else if (name === "desktop.plugins.diagnostics") done({entries: [], host: null});
                else if (name === "desktop.permissions.list") done({grants: []});
                else if (name === "desktop.plugins.development.list") done({artifacts: []});
            }
        }
    }
    function test_pages_data() {
        return [
            {tag: "fallback", url: "../shell/centers/PluginCenter.qml"},
            {tag: "packaged", url: "../shell/providers/settings_plugins/qml/PluginCenter.qml"}
        ];
    }
    function test_literal_query_data() {
        const rows = [];
        for (const page of test_pages_data()) {
            for (const query of [
                {tag: "bold", text: "<b>foo</b>"},
                {tag: "image", text: "<img src='missing.png'>"},
                {tag: "ampersand", text: "&"},
                {tag: "quotes", text: "\"quoted\" 'query'"},
                {tag: "cjk", text: "沒有這個插件"}
            ]) rows.push({tag: page.tag + "/" + query.tag, url: page.url, query: query.text});
        }
        return rows;
    }
    function test_literal_query(data) {
        const component = Qt.createComponent(Qt.resolvedUrl(data.url));
        compare(component.status, Component.Ready, component.errorString());
        const client = createTemporaryObject(clientFactory, testCase);
        const page = createTemporaryObject(component, testCase, {client: client, tokens: tokens, width: 1000, height: 760});
        verify(page !== null);
        page.packages = [summary()];
        const original = JSON.stringify(page.packages);
        const calls = client.calls.length;
        const field = findChild(page, "pluginSearchField");
        const empty = findChild(page, "pluginSearchEmpty");
        const rows = findChild(page, "installedPluginRows");
        field.text = data.query;
        tryCompare(rows, "count", 0);
        verify(empty.visible);
        compare(empty.text, "沒有符合「" + data.query + "」的插件。");
        compare(empty.textFormat, Text.PlainText, "queries must never be interpreted as markup");
        compare(JSON.stringify(page.packages), original);
        // The very same characters are a literal match when supplied as a name.
        page.packages = [Object.assign(summary(), {name: data.query})];
        tryCompare(rows, "count", 1);
        verify(!empty.visible);
        field.text = "";
        tryCompare(rows, "count", 1);
        compare(client.calls.length, calls);
        page.destroy();
    }
    function test_pages(data) {
        const component = Qt.createComponent(Qt.resolvedUrl(data.url));
        compare(component.status, Component.Ready, component.errorString());
        const client = createTemporaryObject(clientFactory, testCase);
        const page = createTemporaryObject(component, testCase, {client: client, tokens: tokens, width: 1000, height: 760});
        verify(page !== null);
        page.packages = [summary(), {package_id: "ditto.other", version: "1.0.0", name: "Other", host_kind: "qml"}];
        page.manifests = {"ditto.weather@1.0.0": manifest()};
        page.entries = entries();
        const original = JSON.stringify([page.packages, page.entries]);
        const calls = client.calls.length;
        const field = findChild(page, "pluginSearchField");
        verify(field !== null);
        compare(field.accessibleName, "搜尋已安裝的插件");
        const rows = findChild(page, "installedPluginRows");
        const empty = findChild(page, "pluginSearchEmpty");
        tryCompare(rows, "count", 2);
        field.focusInput();
        for (const key of [Qt.Key_W, Qt.Key_E, Qt.Key_A, Qt.Key_T, Qt.Key_H, Qt.Key_E, Qt.Key_R]) keyClick(key);
        tryCompare(rows, "count", 1);
        verify(!empty.visible);
        field.text = "calendar";
        tryCompare(rows, "count", 0);
        verify(empty.visible);
        compare(empty.text, "沒有符合「calendar」的插件。");
        keyClick(Qt.Key_Escape);
        compare(field.text, "");
        tryCompare(rows, "count", 2);
        verify(!empty.visible);
        field.text = "預報";
        tryCompare(rows, "count", 1);
        // Existing asynchronous manifest/entry replies must update the view.
        page.manifests = {};
        tryCompare(rows, "count", 0);
        page.manifests = {"ditto.weather@1.0.0": manifest()};
        tryCompare(rows, "count", 1);
        field.text = "forecast-morning";
        tryCompare(rows, "count", 1);
        page.entries = [];
        tryCompare(rows, "count", 0);
        field.text = "";
        tryCompare(rows, "count", 2);
        page.entries = entries();
        compare(JSON.stringify([page.packages, page.entries]), original);
        compare(client.calls.length, calls, "filtering must not call Core");
        page.destroy();
    }
}
