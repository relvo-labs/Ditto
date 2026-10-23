import QtQuick
import QtTest
import Quickshell
import DittoStub
import "../shell/core" as Core
import "../shell/centers" as Centers
import "../shell/jelly" as Jelly
import "../shell/chat" as Chat

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
            property var requests: []
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
            signal disconnected()
            function watchTopics(topics, event, resync, ready, fail) {}
            function newKey(prefix) { return prefix + "-fixture"; }
            function report(observation) { reports = reports.concat([observation]); }
            function t(source) { return source; }
            function key(source, args) { return source; }
            function capability(name, args, done, fail) {
                capabilityCalls = capabilityCalls.concat([name]);
                requests = requests.concat([{method: name, args: args}]);
                if (name === "agent.credentials.create") done({credential_ref: "fixture-ref"});
                else if (name === "agent.settings.patch") done(Object.assign({}, args.settings, {revision: "patched"}));
                else if (name === "agent.settings.describe") done({enabled: false, revision: "fixture", provider: "codex-app-server", approval_mode: "ask"});
                else if (name === "agent.sessions.list") done({sessions: []});
                else if (name === "desktop.appearance.get") done({appearance: {theme: "soft-jelly-light", tokens: {}}, avatar: {enabled: false}});
                else if (name === "desktop.shortcuts.list") done({shortcuts: []});
                else if (name === "desktop.commands.list") done({commands: []});
                else if (name === "desktop.outputs.list") done({outputs: []});
                else if (name === "desktop.panels.list") done({avatar: null});
                else if (name === "desktop.changes.list") done({changes: []});
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
    Component { id: conversationFactory; Chat.ConversationState {} }
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
            {tag: "plugins", id: "plugins", file: "PluginCenter", calls: ["desktop.plugins.list", "desktop.plugins.diagnostics", "desktop.permissions.list", "desktop.plugins.development.list", "desktop.jobs.list"]},
            {tag: "personalization", id: "personalization", file: "PersonalizationCenter", calls: ["desktop.appearance.get", "desktop.profiles.get", "desktop.shortcuts.list", "desktop.commands.list", "desktop.outputs.list", "desktop.panels.list"]},
            {tag: "ai", id: "ai", file: "AISettings", calls: ["agent.settings.describe", "agent.sessions.list"]}
        ];
    }
    function test_packaged_page_uses_sdk_and_opt_in_flickable(data) {
        const s = setup();
        const binding = page(data.id, "../shell/providers/settings_" + data.id + "/qml/" + data.file + ".qml");
        binding.package = "ditto.settings." + data.id;
        binding.settings_page.title_key = "command." + (data.id === "ai" ? "ai_settings" : data.id) + ".open";
        binding.config = {check: true};
        compare(prepare(s.host, "sdk-page", [binding]).items.filter(i => i.key === data.id)[0].status, "ready");
        compare(s.client.capabilityCalls.length, 0);
        s.host.commit("sdk-page");
        compare(s.client.capabilityCalls.length, 0);
        const conversation = createTemporaryObject(conversationFactory, testCase, {client: s.client});
        const center = createTemporaryObject(centerFactory, testCase, {client: s.client, tokens: s.tokens, providers: s.host, aiSettings: conversation.aiSettings, page: data.id});
        tryVerify(() => !!center.currentPageItem);
        verify(!center.pageFallback);
        compare(center.pages.map(p => p.id), ["composition", "plugins", "history", "personalization", "ai"]);
        compare(center.pages.filter(p => p.id === data.id).length, 1);
        compare(center.pages.find(p => p.id === data.id).label, binding.settings_page.title_key);
        compare(center.currentPageItem.pageId, data.id);
        compare(center.currentPageItem.entryId, data.id);
        compare(center.currentPageItem.config.check, true);
        compare(center.pageFlick, center.currentPageItem);
        if (data.id === "ai") {
            compare(center.currentPageItem.aiSettings, conversation.aiSettings);
            verify(center.currentPageItem.aiSettings !== conversation);
            compare(center.currentPageItem.conversation, undefined);
            assertSettingsOnly(conversation.aiSettings);
            compare(center.currentPageItem.settings.enabled, false);
            conversation.settings = Object.assign({}, conversation.settings, {model: "live-model"});
            compare(center.currentPageItem.settings.model, "live-model");
        } else {
            compare(center.currentPageItem.aiSettings, undefined);
            if (data.id === "personalization") compare(center.currentPageItem.providers, undefined);
        }
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
        if (data.id === "ai") {
            compare(center.currentPageItem.aiSettings, conversation.aiSettings);
            compare(center.currentPageItem.conversation, undefined);
        }
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
    function assertSettingsOnly(facade) {
        for (const member of ["conversation", "state", "source", "controller", "owner", "client", "aiSettings", "draft", "events", "sessions",
                "turn", "sessionId", "attached", "attachments", "previews", "streamText", "send", "newConversation"])
            compare(facade[member], undefined, "facade must not expose " + member);
        for (const member of ["open", "setEnabled", "refreshSettings", "useSubscription", "startLogin", "cancelLogin",
                "logout", "refreshProvider", "chooseModel", "saveApiKey", "setApprovalMode"])
            compare(typeof facade[member], "function", member);
    }
    function test_optional_facade_input_tracks_owner_without_recreating_page() {
        const s = setup();
        const first = createTemporaryObject(conversationFactory, testCase, {client: s.client});
        const second = createTemporaryObject(conversationFactory, testCase, {client: s.client});
        first.settings = {enabled: false, model: "first-owner"};
        second.settings = {enabled: false, model: "second-owner"};
        compare(first.aiSettings.settings.model, "first-owner");
        compare(second.aiSettings.settings.model, "second-owner");
        assertSettingsOnly(first.aiSettings);
        assertSettingsOnly(second.aiSettings);
        prepare(s.host, "optional-input", [page("extra", "../fixtures/AiSettingsInput.qml")]);
        s.host.commit("optional-input");
        const center = createTemporaryObject(centerFactory, testCase, {client: s.client, tokens: s.tokens,
            providers: s.host, aiSettings: first.aiSettings, page: "extra"});
        tryVerify(() => !!center.currentPageItem && !center.pageFallback);
        const instance = center.currentPageItem;
        compare(instance.aiSettings, first.aiSettings);
        center.aiSettings = second.aiSettings;
        compare(instance.aiSettings, second.aiSettings);
        first.settings = {enabled: false, model: "changed-first-owner"};
        compare(first.aiSettings.settings.model, "changed-first-owner");
        compare(instance.aiSettings.settings.model, "second-owner");
        compare(center.currentPageItem, instance);
        assertSettingsOnly(instance.aiSettings);
    }
    function test_ai_actions_without_facade_data() {
        return [
            {tag: "builtin", file: "../shell/centers/AISettings.qml"},
            {tag: "package", file: "../shell/providers/settings_ai/qml/AISettings.qml"}
        ];
    }
    function test_ai_actions_without_facade(data) {
        failOnWarning(/TypeError|ReferenceError/);
        const s = setup();
        const component = Qt.createComponent(Qt.resolvedUrl(data.file));
        compare(component.status, Component.Ready, component.errorString());
        const page = createTemporaryObject(component, testCase, {client: s.client, tokens: s.tokens, width: 800, height: 600});
        verify(page !== null);
        compare(page.aiSettings, null);
        const controls = {buttons: [], choices: [], toggles: []};
        function collect(item) {
            if (typeof item.chosen === "function") { controls.choices.push(item); return; }
            if (typeof item.toggled === "function") { controls.toggles.push(item); return; }
            if (typeof item.clicked === "function" && item.kind !== undefined) { controls.buttons.push(item); return; }
            for (const child of item.children || []) collect(child);
        }
        collect(page);
        compare(controls.buttons.length, 6);
        compare(controls.choices.length, 4);
        compare(controls.toggles.length, 1);
        for (const button of controls.buttons) button.clicked();
        for (const choice of controls.choices) {
            choice.chosen("codex-app-server");
            choice.chosen("direct-model");
        }
        controls.toggles[0].toggled(true);
        compare(s.client.capabilityCalls.length, 0);
        compare(page.keyNotice, "");
        compare(page.settings, null);
        page.destroy();
        wait(0);
    }
    function test_facade_readonly_actions_and_key_reference() {
        const s = setup();
        const conversation = createTemporaryObject(conversationFactory, testCase, {client: s.client});
        const facade = conversation.aiSettings;
        assertSettingsOnly(facade);
        facade.open();
        compare(facade.settings, conversation.settings);
        let refused = false;
        try { facade.settings = {enabled: true}; } catch (error) { refused = true; }
        verify(refused, "settings projection must be read-only");
        compare(conversation.settings.enabled, false);
        facade.setEnabled(false);
        facade.chooseModel("fixture-model", "medium");
        compare(conversation.settings.model, "fixture-model");
        compare(facade.settings.reasoning_effort, "medium");
        facade.setApprovalMode("never");
        compare(facade.settings.approval_mode, "never");
        let completed = 0;
        const key = "FAKE-KEY-FACADE-TEST";
        facade.saveApiKey("https://example.invalid/v1", "direct-fixture", key, () => completed++);
        compare(completed, 1);
        const credential = s.client.requests.find(request => request.method === "agent.credentials.create");
        compare(credential.args.secret, key);
        compare(facade.settings.provider, "direct-model");
        compare(facade.settings.endpoint, "https://example.invalid/v1");
        compare(facade.settings.auth.credential_ref, "fixture-ref");
        compare(facade.key, undefined);
        compare(facade.secret, undefined);
        for (const member of ["settings", "provider", "login", "errorText", "errorDiagnostic"])
            verify(JSON.stringify(facade[member]).indexOf(key) < 0, member + " must not retain a key value");
        facade.useSubscription();
        compare(facade.settings.provider, "codex-app-server");
        compare(facade.settings.auth, null);
        conversation.login = {auth_url: "https://example.invalid/login", user_code: "FIXTURE-CODE"};
        compare(facade.login.user_code, "FIXTURE-CODE");
        conversation.login = null;
        compare(facade.login, null);
        facade.refreshSettings();
        verify(s.client.capabilityCalls.filter(name => name === "agent.settings.describe").length >= 2);
        assertSettingsOnly(facade);
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

    // #171: both history pages (built-in and packaged, as staged) show a
    // saved_only change whose Profile Core says is deleted without an undo
    // button, and keep it for the same change while the Profile exists.
    Component {
        id: historyClientFactory
        QtObject {
            property var summaries: []
            property var records: ({})
            property var tr: QtObject {
                function slotName(slot) { return slot; }
                function packageName(id) { return id; }
                function has(key) { return false; }
            }
            signal capabilitiesReloaded()
            signal changeUpdated(var change)
            function t(source) { return source; }
            function key(source, args) { return source; }
            function join(values) { return values.join(", "); }
            function errorText(error) { return String(error); }
            function diagnosticText(error) { return ""; }
            function capability(name, args, done, fail) {
                if (name === "desktop.changes.list") done({changes: summaries});
                else if (name === "desktop.changes.get") done(records[args.change_id]);
            }
            function undoChange(changeId, done, fail) {}
        }
    }
    function historySummary(changeId, savedOnly) {
        return {change_id: changeId, profile_id: "prf-dev", state: "committed", result: "succeeded", origin: {kind: "cli"},
            hot_swap_level: "instant", title_key: "change.title.appearance", committed_revision: "rev-1",
            confirmation: {state: "not_required"}, saved_only: savedOnly,
            created_at: "2026-10-23T00:00:00.000Z", updated_at: "2026-10-23T00:00:00.000Z"};
    }
    function historyRecord(changeId, savedOnly) {
        return Object.assign(historySummary(changeId, savedOnly), {base_revision: "rev-0", idempotency_key: null, ops: [],
            card: {kind: "appearance", title_key: "change.title.appearance", title_args: {}, items: []},
            reasons: [], items: [], operations: []});
    }
    function itemsWithText(item, text) {
        let found = item.text === text ? [item] : [];
        for (let i = 0; i < item.children.length; ++i) found = found.concat(itemsWithText(item.children[i], text));
        return found;
    }
    function test_history_pages_hide_undo_for_a_deleted_target_data() {
        return [
            {tag: "built-in", url: "../shell/centers/HistoryCenter.qml"},
            {tag: "packaged", url: "../shell/providers/settings_history/qml/HistoryPage.qml"}
        ];
    }
    function test_history_pages_hide_undo_for_a_deleted_target(data) {
        const kept = {reason: "inactive_profile", profile_name: "開發"};
        const gone = {reason: "inactive_profile", profile_name: "開發", profile_deleted: true};
        const client = createTemporaryObject(historyClientFactory, testCase, {
            summaries: [historySummary("chg-gone", gone), historySummary("chg-kept", kept)],
            records: {"chg-gone": historyRecord("chg-gone", gone), "chg-kept": historyRecord("chg-kept", kept)}});
        const tokens = createTemporaryObject(tokenFactory, testCase);
        const component = Qt.createComponent(Qt.resolvedUrl(data.url));
        compare(component.status, Component.Ready, component.errorString());
        const page = createTemporaryObject(component, testCase, {client: client, tokens: tokens, width: 900, height: 700});
        verify(page !== null);
        tryCompare(page.changes, "length", 2);
        page.open("chg-gone");
        page.open("chg-kept");
        tryVerify(() => !!page.expanded["chg-gone"] && !!page.expanded["chg-kept"]);
        wait(0);
        // The list row of the deleted target says so.
        verify(itemsWithText(page, "曾存到「開發」（已刪除）").length >= 1);
        // Rows follow the list order: the deleted target first. Only the
        // buttons themselves (a Button has an accessibleName), not their labels.
        const undo = itemsWithText(page, "撤銷這次變更").filter(item => item.accessibleName !== undefined);
        compare(undo.length, 2);
        verify(!undo[0].visible, "undo offered for a change on a deleted Profile");
        verify(undo[1].visible, "undo missing for a change on an existing Profile");
        page.destroy();
        wait(0);
    }
}
