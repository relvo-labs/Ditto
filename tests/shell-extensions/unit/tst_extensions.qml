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
            signal capabilitiesReloaded()
            signal changeUpdated(var change)
            function report(observation) { reports = reports.concat([observation]); }
            function t(source) { return source; }
            function key(source, args) { return source; }
            function capability(name, args, done, fail) {
                capabilityCalls = capabilityCalls.concat([name]);
                if (name === "desktop.changes.list") done({changes: []});
                else if (name === "desktop.profiles.list") done({profiles: []});
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
    function test_packaged_history_uses_sdk_and_opt_in_flickable() {
        const s = setup();
        const binding = page("history", "../shell/providers/settings_history/qml/HistoryPage.qml");
        binding.config = {check: true};
        compare(prepare(s.host, "sdk-page", [binding]).items.filter(i => i.key === "history")[0].status, "ready");
        compare(s.client.capabilityCalls.length, 0);
        s.host.commit("sdk-page");
        compare(s.client.capabilityCalls.length, 0);
        const center = createTemporaryObject(centerFactory, testCase, {client: s.client, tokens: s.tokens, providers: s.host, page: "history"});
        tryVerify(() => !!center.currentPageItem);
        verify(!center.pageFallback);
        compare(center.currentPageItem.pageId, "history");
        compare(center.currentPageItem.entryId, "history");
        compare(center.currentPageItem.config.check, true);
        compare(center.pageFlick, center.currentPageItem);
        compare(s.client.capabilityCalls, ["desktop.changes.list"]);
        const instance = center.currentPageItem;
        prepare(s.host, "unrelated", [binding]); s.host.commit("unrelated");
        wait(0);
        compare(center.currentPageItem, instance);
        compare(s.client.capabilityCalls, ["desktop.changes.list"]);
        center.visible = false;
        tryVerify(() => center.currentPageItem === null);
        compare(s.client.capabilityCalls, ["desktop.changes.list"]);
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
