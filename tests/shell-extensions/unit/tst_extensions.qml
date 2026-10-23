import QtQuick
import QtTest
import Quickshell
import DittoStub
import "../shell/core" as Core
import "../shell/centers" as Centers
import "../shell/jelly" as Jelly

TestCase {
    id: testCase
    name: "ShellExtensions"
    when: windowShown
    visible: true
    function initTestCase() { StubDesktop.layer = testCase; Quickshell.screens = [screenFixture]; }
    QtObject { id: screenFixture; property string name: "test"; property int width: 1100; property int height: 760 }
    width: 1100
    height: 760

    Component {
        id: clientFactory
        QtObject {
            property int pageCreations: 0
            property int pageDestructions: 0
            property var reports: []
            property var capabilityCalls: []
            property bool online: true
            property string status: ""
            property var tr: QtObject {
                function slotName(slot) { return slot; }
                function packageName(id) { return id; }
                function has(key) { return false; }
            }
            signal capabilitiesReloaded()
            signal changeUpdated(var change)
            signal profileChanged(var profile)
            signal panelsReported(var panels)
            signal jobUpdated(var job)
            function report(observation) { reports = reports.concat([observation]); }
            function t(source) { return source; }
            function key(source, args) { return source; }
            function capability(name, args, done, fail) {
                capabilityCalls = capabilityCalls.concat([name]);
                if (name === "desktop.changes.list") done({changes: []});
                else if (name === "desktop.profiles.list") done({profiles: []});
                else if (name === "desktop.profiles.get") done({profile: {profile_id: "test", name: "Test"}, document: {entries: [], slots: {}}, history: []});
                else if (name === "desktop.plugins.list") done({entries: [], packages: []});
                else if (name === "desktop.layout.get") done({available: []});
                else if (name === "desktop.plugins.diagnostics") done({entries: [], host: null});
                else if (name === "desktop.permissions.list") done({grants: []});
                else if (name === "desktop.plugins.development.list") done({artifacts: []});
                else if (name === "desktop.jobs.list") done({jobs: []});
            }
        }
    }
    Component { id: tokenFactory; Jelly.Tokens { readsSystemPreference: false } }
    Component { id: hostFactory; Core.ProviderHost {} }
    Component { id: centerFactory; Centers.Centers {} }
    Component { id: fallbackFactory; Core.BackgroundFallback {} }

    function setup() {
        const client = createTemporaryObject(clientFactory, testCase);
        const tokens = createTemporaryObject(tokenFactory, testCase);
        const host = createTemporaryObject(hostFactory, testCase, {client: client, tokens: tokens});
        verify(host !== null);
        return {client: client, tokens: tokens, host: host};
    }
    function page(id, url, order, entry) {
        return {slot: "ui.settings_page", entry_id: entry || id, package: "ditto.test." + id,
            version: "1.0.0", config: {}, qml_url: Qt.resolvedUrl(url || "../fixtures/Page.qml").toString(),
            settings_page: {page_id: id, title_key: "title." + id, order: order || 0}};
    }
    function prepare(host, id, bindings) {
        let reply = null;
        host.prepare({change_id: id, origin: "test", target: {role: "shell", slots: bindings,
            appearance: {}, avatar: {}, shortcuts: []}}, result => { reply = result; });
        tryVerify(() => reply !== null, 8000);
        return reply;
    }
    function test_page_prepare_commit_upgrade_rollback_and_abort() {
        const s = setup();
        const binding = page("history");
        compare(prepare(s.host, "first", [binding]).items.filter(i => i.key === "history")[0].status, "ready");
        compare(s.client.pageCreations, 0);
        compare(s.host.registeredPages.length, 0);
        s.host.commit("first");
        compare(s.client.pageCreations, 0);
        compare(s.host.registeredPages.length, 1);
        const original = s.host.registeredPages[0].component;
        const mount = s.host.observation().mounts[0];
        compare(mount.package, binding.package);
        compare(mount.version, "1.0.0");
        compare(mount.page_state, "registered");
        verify(mount.mounted && mount.visible);
        const upgrade = Object.assign({}, binding, {version: "2.0.0", config: {newer: true}});
        prepare(s.host, "upgrade", [upgrade]);
        s.host.commit("upgrade");
        compare(s.host.observation().mounts[0].version, "2.0.0");
        s.host.rollback("upgrade");
        compare(s.host.registeredPages.length, 1);
        compare(s.host.registeredPages[0].component, original);
        compare(s.host.observation().mounts[0].version, "1.0.0");
        compare(s.host.registeredPages[0].config.newer, undefined);
        prepare(s.host, "aborted", [upgrade]);
        s.host.abort("aborted");
        compare(s.host.observation().mounts[0].version, "1.0.0");
        compare(s.client.pageCreations, 0);
    }
    function test_broken_page_prepare_fails_and_keeps_registration() {
        const s = setup();
        prepare(s.host, "good", [page("history")]); s.host.commit("good");
        const reply = prepare(s.host, "broken", [page("history", "../fixtures/Broken.qml")]);
        compare(reply.items[0].status, "failed");
        s.host.abort("broken");
        compare(s.host.registeredPages.length, 1);
        compare(s.client.pageCreations, 0);
    }
    function test_centers_replace_append_order_fallback_and_closed_lifecycle() {
        const s = setup();
        prepare(s.host, "pages", [page("zebra", null, 20), page("history", null, 30), page("alpha", null, 20)]);
        s.host.commit("pages");
        const center = createTemporaryObject(centerFactory, testCase, {client: s.client, tokens: s.tokens, providers: s.host, page: "history"});
        verify(center !== null);
        tryVerify(() => !!center.currentPageItem);
        compare(center.pages.map(p => p.id), ["composition", "plugins", "history", "personalization", "ai", "alpha", "zebra"]);
        compare(center.pages.filter(p => p.id === "history").length, 1);
        compare(center.pages[2].label, "title.history");
        tryCompare(s.client, "pageCreations", 1);
        compare(center.currentPageItem.entryId, "history");
        compare(center.pageFlick, null); // Plain Item: no Flickable assumption.
        compare(s.host.observation().mounts.filter(m => m.entry_id === "history")[0].page_state, "open");
        center.visible = false;
        tryCompare(s.client, "pageDestructions", 1);
        compare(s.host.openPageEntry, "");
        center.visible = true;
        tryCompare(s.client, "pageCreations", 2);
        const broken = page("history", "../fixtures/InstantiationFailure.qml");
        prepare(s.host, "bad-instance", [broken]); s.host.commit("bad-instance");
        tryVerify(() => center.pageFallback && !!center.currentPageItem);
        verify(center.pageFlick !== null); // Trusted HistoryCenter fallback.
        compare(center.currentPageItem.entryId, undefined);
        const registered = s.host.observation().mounts.filter(m => m.entry_id === "history")[0];
        verify(registered.mounted && registered.visible);
        compare(registered.page_state, "registered");
        s.host.rollback("bad-instance");
        tryVerify(() => !center.pageFallback);
        center.page = "alpha";
        tryVerify(() => center.currentPageItem && center.currentPageItem.pageId === "alpha");
        // Extra page failure has a visible text fallback, no blank content.
        prepare(s.host, "bad-extra", [page("alpha", "../fixtures/ExtraFailure.qml")]); s.host.commit("bad-extra");
        tryVerify(() => center.pageFallback && center.currentPageItem === null);
        verify(findChild(center, "settingsPageError").visible);
    }
    function test_sidebar_focus_survives_an_unrelated_slot_commit() {
        const s = setup();
        const binding = page("history");
        prepare(s.host, "page", [binding]); s.host.commit("page");
        const center = createTemporaryObject(centerFactory, testCase, {client: s.client, tokens: s.tokens, providers: s.host, page: "history"});
        tryVerify(() => !!center.currentPageItem);
        const tab = findChild(center, "settingsTab_history");
        verify(tab !== null);
        tab.forceActiveFocus(Qt.TabFocusReason);
        verify(tab.activeFocus);
        const registrations = s.host.registeredPages;
        const unrelated = {slot: "ui.background", entry_id: "background", package: "ditto.background.default", version: "1.0.0", config: {},
            qml_url: Qt.resolvedUrl("../shell/providers/background_default/qml/Background.qml").toString()};
        prepare(s.host, "unrelated-slot", [binding, unrelated]); s.host.commit("unrelated-slot");
        wait(0);
        verify(s.host.registeredPages === registrations);
        compare(findChild(center, "settingsTab_history"), tab);
        verify(tab.activeFocus);
        center.destroy();
        s.host.destroy();
        wait(0);
    }
    function test_removed_or_restored_missing_extra_page_returns_to_composition() {
        const s = setup();
        prepare(s.host, "extra", [page("extra")]); s.host.commit("extra");
        const center = createTemporaryObject(centerFactory, testCase, {client: s.client, tokens: s.tokens, providers: s.host, page: "extra"});
        tryVerify(() => center.currentPageItem && center.currentPageItem.pageId === "extra");
        prepare(s.host, "remove-extra", []); s.host.commit("remove-extra");
        tryCompare(center, "page", "composition");
        verify(!findChild(center, "settingsPageError").visible);
        const restored = createTemporaryObject(centerFactory, testCase, {client: s.client, tokens: s.tokens, providers: s.host, page: "missing_extra"});
        tryCompare(restored, "page", "composition");
        verify(!findChild(restored, "settingsPageError").visible);
        center.destroy();
        restored.destroy();
        wait(0);
    }
    function test_packaged_page_uses_sdk_and_opt_in_flickable_data() {
        return [
            {tag: "history", id: "history", file: "HistoryPage", calls: ["desktop.changes.list"]},
            {tag: "composition", id: "composition", file: "CompositionCenter", calls: ["desktop.profiles.list", "desktop.profiles.get", "desktop.plugins.list", "desktop.layout.get"]},
            {tag: "plugins", id: "plugins", file: "PluginCenter", calls: ["desktop.plugins.list", "desktop.plugins.diagnostics", "desktop.permissions.list", "desktop.plugins.development.list", "desktop.jobs.list"]}
        ];
    }
    function test_packaged_page_uses_sdk_and_opt_in_flickable(data) {
        const s = setup();
        const binding = page(data.id, "../shell/providers/settings_" + data.id + "/qml/" + data.file + ".qml");
        binding.package = "ditto.settings." + data.id;
        binding.settings_page.title_key = "command." + data.id + ".open";
        binding.config = {check: true};
        compare(prepare(s.host, "sdk-page", [binding]).items.filter(i => i.key === data.id)[0].status, "ready");
        compare(s.client.capabilityCalls.length, 0);
        s.host.commit("sdk-page");
        compare(s.client.capabilityCalls.length, 0);
        const center = createTemporaryObject(centerFactory, testCase, {client: s.client, tokens: s.tokens, providers: s.host, page: data.id});
        tryVerify(() => !!center.currentPageItem);
        verify(!center.pageFallback);
        compare(center.pages.map(p => p.id), ["composition", "plugins", "history", "personalization", "ai"]);
        compare(center.pages.filter(p => p.id === data.id).length, 1);
        compare(center.pages.find(p => p.id === data.id).label, binding.settings_page.title_key);
        compare(center.currentPageItem.pageId, data.id);
        compare(center.currentPageItem.entryId, data.id);
        compare(center.currentPageItem.config.check, true);
        compare(center.pageFlick, center.currentPageItem);
        const expectedCalls = data.calls.slice().sort();
        compare(s.client.capabilityCalls.slice().sort(), expectedCalls);
        const mount = s.host.observation().mounts.find(m => m.entry_id === data.id);
        compare(mount.package, binding.package);
        compare(mount.version, binding.version);
        compare(mount.page_state, "open");
        const tab = findChild(center, "settingsTab_" + data.id);
        verify(tab !== null);
        tab.forceActiveFocus(Qt.TabFocusReason);
        verify(tab.activeFocus);
        const instance = center.currentPageItem;
        const unrelated = {slot: "ui.background", entry_id: "background", package: "ditto.background.default", version: "1.0.0", config: {},
            qml_url: Qt.resolvedUrl("../shell/providers/background_default/qml/Background.qml").toString()};
        prepare(s.host, "unrelated", [binding, unrelated]); s.host.commit("unrelated");
        wait(0);
        compare(center.currentPageItem, instance);
        compare(findChild(center, "settingsTab_" + data.id), tab);
        verify(tab.activeFocus);
        compare(s.client.capabilityCalls.slice().sort(), expectedCalls);
        center.visible = false;
        tryVerify(() => center.currentPageItem === null);
        compare(s.client.capabilityCalls.slice().sort(), expectedCalls);
        center.visible = true;
        tryVerify(() => !!center.currentPageItem && !center.pageFallback);
        compare(center.currentPageItem.pageId, data.id);
        // A committed page can compile successfully yet fail on creation.
        const broken = page(data.id, "../fixtures/InstantiationFailure.qml");
        broken.package = binding.package;
        broken.version = "2.0.0";
        compare(prepare(s.host, "bad-instance", [broken]).items.find(i => i.key === data.id).status, "ready");
        s.host.commit("bad-instance");
        tryVerify(() => center.pageFallback && !!center.currentPageItem);
        verify(center.pageFlick !== null);
        compare(center.currentPageItem.entryId, undefined);
        compare(center.pages.filter(p => p.id === data.id).length, 1);
        compare(s.host.openPageEntry, "");
        compare(s.host.observation().mounts.find(m => m.entry_id === data.id).page_state, "registered");
        s.host.rollback("bad-instance");
        tryVerify(() => !!center.currentPageItem && !center.pageFallback);
        compare(center.currentPageItem.pageId, data.id);
        compare(center.currentPageItem.entryId, binding.entry_id);
        compare(center.currentPageItem.config.check, true);
        center.destroy();
        s.host.destroy();
        wait(0);
    }
    function test_background_fallback_commit_release_and_rollback() {
        const s = setup();
        const fallback = createTemporaryObject(fallbackFactory, testCase, {providers: s.host, tokens: s.tokens});
        verify(fallback.shown);
        const fallbackSurface = findChild(fallback, "stubPanelWindow");
        verify(fallbackSurface !== null && fallbackSurface.visible);
        const binding = {slot: "ui.background", entry_id: "background", package: "ditto.background.default", version: "1.0.0", config: {},
            qml_url: Qt.resolvedUrl("../shell/providers/background_default/qml/Background.qml").toString()};
        const result = prepare(s.host, "background", [binding]);
        compare(result.items.filter(i => i.key === "ui.background")[0].status, "ready");
        verify(fallback.shown);
        s.host.commit("background");
        verify(s.host.backgroundShown);
        verify(!fallback.shown);
        verify(!fallbackSurface.visible);
        const providerSurface = findChild(s.host.item("ui.background"), "stubPanelWindow");
        verify(providerSurface !== null && providerSurface.visible);
        compare(s.host.observation().mounts[0].package, binding.package);
        compare(s.host.observation().mounts[0].version, "1.0.0");
        s.host.item("ui.background").release();
        verify(!providerSurface.visible);
        verify(fallback.shown);
        verify(fallbackSurface.visible);
        s.host.rollback("background");
        verify(fallback.shown);
        verify(!s.host.backgroundShown);
    }
}
