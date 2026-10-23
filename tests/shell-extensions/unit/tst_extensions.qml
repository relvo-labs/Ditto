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
            /// desktop.profiles.delete fails with this error when set.
            property var deleteError: null
            function errorText(error) { return "generic: " + (error && error.name); }
            function diagnosticText(error) { return error ? error.name : ""; }
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
                else if (name === "desktop.profiles.delete") {
                    if (deleteError) fail(deleteError);
                    else done({profile_id: args.profile_id, name: "Test"});
                }
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

    // #171: the history pages (built-in and packaged, as staged) and the
    // chat's change card follow Core's record-level `profile_deleted`: no
    // undo button and no undo promise for a change whose Profile is deleted,
    // whether it was saved_only or applied, both when the record is read
    // fresh and when the view already holds it as the Profile is deleted
    // (Core then publishes change_updated for those changes).
    Component {
        id: historyClientFactory
        QtObject {
            property var summaries: []
            property var records: ({})
            property bool online: true
            property var packages: []
            property var gets: []
            property var tr: QtObject {
                function slotName(slot) { return slot; }
                function packageName(id) { return id; }
                function has(key) { return false; }
            }
            signal capabilitiesReloaded()
            signal changeUpdated(var change)
            signal profileChanged(var profile)
            signal disconnected()
            function t(source) { return source; }
            function key(source, args) { return source; }
            function join(values) { return values.join(", "); }
            function errorText(error) { return String(error); }
            function diagnosticText(error) { return ""; }
            function newKey(prefix) { return prefix + "-fixture"; }
            function watchTopics(topics, event, resync, ready, fail) {}
            function capabilityAvailable(name) { return false; }
            /// While true, reads wait in `held` until the test answers them,
            /// in any order, with what Core had when the read was sent.
            property bool hold: false
            property var held: []
            function capability(name, args, done, fail) {
                let value;
                if (name === "desktop.changes.list") value = {changes: summaries};
                else if (name === "desktop.changes.get") {
                    gets = gets.concat([args.change_id]);
                    value = records[args.change_id];
                } else return;
                if (hold) held = held.concat([{name: name, changeId: args.change_id, done: done, value: value}]);
                else if (name === "desktop.changes.list") done(value);
                // Answered later, as over the socket.
                else Qt.callLater(() => done(value));
            }
            function heldGets() { return held.filter(call => call.name === "desktop.changes.get"); }
            function heldLists() { return held.filter(call => call.name === "desktop.changes.list"); }
            /// Answer the held call `call` now, with a copy of what was read
            /// then (so a view that applied it holds a new object).
            function answer(call) {
                held = held.filter(other => other !== call);
                call.done(JSON.parse(JSON.stringify(call.value)));
            }
            function undoChange(changeId, done, fail) {}
            /// What Core does when the Profile is deleted: every read now
            /// carries profile_deleted, and change_updated goes out for the
            /// committed changes of that Profile.
            function deleteProfile(profileId, quietly) {
                const table = {};
                for (const id in records) {
                    table[id] = Object.assign({}, records[id], records[id].profile_id === profileId ? {profile_deleted: true} : {});
                }
                records = table;
                summaries = summaries.map(summary => summary.profile_id === profileId ? Object.assign({}, summary, {profile_deleted: true}) : summary);
                // Quietly: as when Core asks subscribers to resync instead.
                if (quietly) return;
                for (const id in records) {
                    if (records[id].profile_id === profileId) changeUpdated(summaryOf(records[id]));
                }
            }
            function summaryOf(record) {
                const summary = {};
                for (const field of ["change_id", "profile_id", "state", "result", "origin", "hot_swap_level", "committed_revision",
                                     "confirmation", "saved_only", "profile_deleted", "created_at", "updated_at"]) {
                    if (record[field] !== undefined) summary[field] = record[field];
                }
                summary.title_key = record.card.title_key;
                return summary;
            }
        }
    }
    Component { id: chatFactory; Chat.ChatBody {} }
    readonly property var savedToDev: ({reason: "inactive_profile", profile_name: "開發"})
    function historyRecord(changeId, profileId, savedOnly, deleted) {
        const record = {change_id: changeId, profile_id: profileId, state: "committed", result: "succeeded", origin: {kind: "cli"},
            hot_swap_level: "instant", committed_revision: "rev-1", confirmation: {state: "not_required"},
            created_at: "2026-10-23T00:00:00.000Z", updated_at: "2026-10-23T00:00:00.000Z",
            base_revision: "rev-0", idempotency_key: null, ops: [],
            card: {kind: "appearance", title_key: "change.title.appearance", title_args: {}, items: []},
            reasons: [], items: [], operations: []};
        if (savedOnly) record.saved_only = savedOnly;
        if (deleted) record.profile_deleted = true;
        return record;
    }
    /// A client holding these records, newest first in the history list.
    function historyClient(records) {
        const client = createTemporaryObject(historyClientFactory, testCase);
        const table = {};
        for (const record of records) table[record.change_id] = record;
        client.records = table;
        client.summaries = records.map(record => client.summaryOf(record));
        return client;
    }
    function itemsWithText(item, text) {
        let found = item.text === text ? [item] : [];
        for (let i = 0; i < item.children.length; ++i) found = found.concat(itemsWithText(item.children[i], text));
        return found;
    }
    /// Buttons only (a Button has an accessibleName), not their labels.
    function buttonsWithText(item, text) {
        return itemsWithText(item, text).filter(found => found.accessibleName !== undefined);
    }
    function historyPage(url, client) {
        const tokens = createTemporaryObject(tokenFactory, testCase);
        const component = Qt.createComponent(Qt.resolvedUrl(url));
        compare(component.status, Component.Ready, component.errorString());
        const page = createTemporaryObject(component, testCase, {client: client, tokens: tokens, width: 900, height: 900});
        verify(page !== null);
        tryCompare(page.changes, "length", client.summaries.length);
        return page;
    }
    function historyPages_data() {
        return [
            {tag: "built-in", url: "../shell/centers/HistoryCenter.qml"},
            {tag: "packaged", url: "../shell/providers/settings_history/qml/HistoryPage.qml"}
        ];
    }
    function test_history_pages_hide_undo_for_a_deleted_profile_data() { return historyPages_data(); }
    function test_history_pages_hide_undo_for_a_deleted_profile(data) {
        const client = historyClient([
            historyRecord("chg-03", "prf-dev", savedToDev, true),
            historyRecord("chg-02", "prf-old", null, true),
            historyRecord("chg-01", "prf-dev2", savedToDev, false)]);
        const page = historyPage(data.url, client);
        for (const id of ["chg-03", "chg-02", "chg-01"]) page.open(id);
        tryVerify(() => ["chg-03", "chg-02", "chg-01"].every(id => !!page.expanded[id]));
        wait(0);
        verify(itemsWithText(page, "曾存到「開發」（已刪除）").length >= 1);
        verify(itemsWithText(page, "已套用並確認生效。這個組合之後已刪除，所以不能撤銷。").length === 1);
        // Rows follow the list order.
        const undo = buttonsWithText(page, "撤銷這次變更");
        compare(undo.length, 3);
        verify(!undo[0].visible, "undo offered for a saved change of a deleted Profile");
        verify(!undo[1].visible, "undo offered for an applied change of a deleted Profile");
        verify(undo[2].visible, "undo missing for a change of an existing Profile");
        page.destroy();
        wait(0);
    }
    function test_open_history_pages_follow_a_profile_deletion_data() { return historyPages_data(); }
    function test_open_history_pages_follow_a_profile_deletion(data) {
        const client = historyClient([
            historyRecord("chg-03", "prf-other", null, false),
            historyRecord("chg-02", "prf-dev", savedToDev, false),
            historyRecord("chg-01", "prf-dev", null, false)]);
        // Older than the loaded rows: not in this view.
        client.records = Object.assign({"chg-00": historyRecord("chg-00", "prf-dev", null, false)}, client.records);
        const page = historyPage(data.url, client);
        page.open("chg-02");
        page.open("chg-01");
        tryVerify(() => !!page.expanded["chg-02"] && !!page.expanded["chg-01"]);
        wait(0);
        // One per row (rows follow the list order); the unopened row has none shown.
        let undo = buttonsWithText(page, "撤銷這次變更");
        compare(undo.length, 3);
        verify(!undo[0].visible && undo[1].visible && undo[2].visible);
        verify(itemsWithText(page, "已存到「開發」，桌面沒有改變；切換到這個組合時才會套用。可以撤銷。").length === 1);
        verify(itemsWithText(page, "已套用並確認生效。可以撤銷。").length === 1);

        client.deleteProfile("prf-dev");
        // The page is not recreated; its rows and open cards read again.
        tryVerify(() => itemsWithText(page, "已套用並確認生效。這個組合之後已刪除，所以不能撤銷。").length === 1);
        tryVerify(() => itemsWithText(page, "曾存到「開發」，桌面沒有改變；這個組合已刪除，所以不會再套用，也不能撤銷。").length === 1);
        verify(itemsWithText(page, "曾存到「開發」（已刪除）").length >= 1);
        compare(itemsWithText(page, "已存到「開發」，桌面沒有改變；切換到這個組合時才會套用。可以撤銷。").length, 0);
        compare(itemsWithText(page, "已套用並確認生效。可以撤銷。").length, 0);
        undo = buttonsWithText(page, "撤銷這次變更");
        compare(undo.length, 3);
        verify(undo.every(button => !button.visible), "undo still offered after the Profile was deleted");
        // An older change the page never loaded is not put at the top.
        compare(page.changes.map(change => change.change_id), ["chg-03", "chg-02", "chg-01"]);
        verify(page.changes[1].profile_deleted === true && page.changes[2].profile_deleted === true);
        verify(page.changes[0].profile_deleted === undefined);
        page.destroy();
        wait(0);
    }
    function test_an_open_chat_card_follows_a_profile_deletion() {
        const client = historyClient([historyRecord("chg-01", "prf-dev", null, false)]);
        const tokens = createTemporaryObject(tokenFactory, testCase);
        const conversation = createTemporaryObject(conversationFactory, testCase, {client: client});
        const chat = createTemporaryObject(chatFactory, testCase, {client: client, tokens: tokens, conversation: conversation,
            width: 800, height: 700});
        verify(chat !== null);
        conversation.events = [{type: "tool/result", data: {change_id: "chg-01"}}];
        tryVerify(() => buttonsWithText(chat, "撤銷這項變更").length === 1 && buttonsWithText(chat, "撤銷這項變更")[0].visible);
        const undo = buttonsWithText(chat, "撤銷這項變更")[0];
        verify(itemsWithText(chat, "已套用並確認生效。可以撤銷。").length === 1);
        const reads = client.gets.length;

        client.deleteProfile("prf-dev");
        // The same card and button: the record is read again from Core.
        tryVerify(() => !undo.visible, 3000, "undo still offered after the Profile was deleted");
        compare(buttonsWithText(chat, "撤銷這項變更")[0], undo);
        verify(client.gets.length > reads);
        verify(itemsWithText(chat, "已套用並確認生效。這個組合之後已刪除，所以不能撤銷。").length === 1);
        compare(itemsWithText(chat, "已套用並確認生效。可以撤銷。").length, 0);
        // The full record (with its card) is kept, not the summary.
        verify(!!chat.records["chg-01"].card);
        compare(chat.records["chg-01"].profile_deleted, true);
        chat.destroy();
        wait(0);
    }

    // #171 R2: answers come back in any order. A read sent before the
    // Profile was deleted that lands after the deletion update (and after a
    // resync) must not bring back the undo promise or button, and overlapping
    // updates of one change send a bounded number of reads.
    function test_open_history_pages_ignore_a_late_answer_from_before_the_delete_data() { return historyPages_data(); }
    function test_open_history_pages_ignore_a_late_answer_from_before_the_delete(data) {
        const client = historyClient([historyRecord("chg-02", "prf-dev", savedToDev, false),
                                      historyRecord("chg-01", "prf-dev", null, false)]);
        const page = historyPage(data.url, client);
        page.open("chg-02");
        page.open("chg-01");
        tryVerify(() => !!page.expanded["chg-02"] && !!page.expanded["chg-01"]);
        client.hold = true;
        // Something re-reads both records and the list before the delete (a
        // confirm, a reconnect).
        client.changeUpdated(client.summaryOf(client.records["chg-02"]));
        client.changeUpdated(client.summaryOf(client.records["chg-01"]));
        client.capabilitiesReloaded();
        compare(client.heldGets().length, 2);
        compare(client.heldLists().length, 1);
        client.deleteProfile("prf-dev");
        client.capabilitiesReloaded();
        // Each change: one read out, one queued, whatever arrived meanwhile;
        // the list likewise.
        compare(client.heldGets().length, 2, "overlapping reads were not coalesced");
        compare(client.heldLists().length, 1, "overlapping list reads were not coalesced");
        // The update itself already says the Profile is deleted.
        let undo = buttonsWithText(page, "撤銷這次變更");
        verify(undo.every(button => !button.visible));
        // The old answers land late, the list read before the delete too.
        for (const call of client.held.slice()) client.answer(call);
        wait(0);
        compare(page.expanded["chg-02"].profile_deleted, true);
        compare(page.expanded["chg-01"].profile_deleted, true);
        undo = buttonsWithText(page, "撤銷這次變更");
        verify(undo.every(button => !button.visible), "a late answer brought undo back");
        compare(itemsWithText(page, "已套用並確認生效。可以撤銷。").length, 0);
        verify(itemsWithText(page, "曾存到「開發」（已刪除）").length >= 1, "a late list answer undid the row");
        // Then the reads sent after the delete.
        compare(client.heldGets().length, 2);
        compare(client.heldLists().length, 1);
        for (const call of client.held.slice()) client.answer(call);
        wait(0);
        compare(client.held.length, 0);
        verify(buttonsWithText(page, "撤銷這次變更").every(button => !button.visible));
        verify(itemsWithText(page, "已套用並確認生效。這個組合之後已刪除，所以不能撤銷。").length === 1);
        page.destroy();
        wait(0);
    }
    function test_open_history_pages_drop_a_late_answer_after_a_resync_data() { return historyPages_data(); }
    function test_open_history_pages_drop_a_late_answer_after_a_resync(data) {
        const client = historyClient([historyRecord("chg-01", "prf-dev", null, false)]);
        const page = historyPage(data.url, client);
        page.open("chg-01");
        tryVerify(() => !!page.expanded["chg-01"]);
        client.hold = true;
        client.changeUpdated(client.summaryOf(client.records["chg-01"]));
        const before = page.expanded["chg-01"];
        // Core could not publish the changes, so it asked for a resync.
        client.deleteProfile("prf-dev", true);
        client.capabilitiesReloaded();
        compare(client.heldGets().length, 1);
        for (const call of client.held.slice()) client.answer(call);
        wait(0);
        compare(page.expanded["chg-01"], before, "a stale answer was applied after the resync");
        compare(client.heldGets().length, 1, "no read after the resync");
        for (const call of client.held.slice()) client.answer(call);
        wait(0);
        compare(page.expanded["chg-01"].profile_deleted, true);
        verify(buttonsWithText(page, "撤銷這次變更").every(button => !button.visible));
        page.destroy();
        wait(0);
    }
    function test_an_open_chat_card_ignores_a_late_answer_from_before_the_delete() {
        const client = historyClient([historyRecord("chg-01", "prf-dev", null, false)]);
        const tokens = createTemporaryObject(tokenFactory, testCase);
        const conversation = createTemporaryObject(conversationFactory, testCase, {client: client});
        const chat = createTemporaryObject(chatFactory, testCase, {client: client, tokens: tokens, conversation: conversation,
            width: 800, height: 700});
        conversation.events = [{type: "tool/result", data: {change_id: "chg-01"}}];
        tryVerify(() => buttonsWithText(chat, "撤銷這項變更").length === 1 && buttonsWithText(chat, "撤銷這項變更")[0].visible);
        const undo = buttonsWithText(chat, "撤銷這項變更")[0];
        client.hold = true;
        client.changeUpdated(client.summaryOf(client.records["chg-01"]));
        compare(client.heldGets().length, 1);
        client.deleteProfile("prf-dev");
        client.changeUpdated(client.summaryOf(client.records["chg-01"]));
        client.capabilitiesReloaded();
        compare(client.heldGets().length, 1, "overlapping reads were not coalesced");
        verify(!undo.visible);
        client.answer(client.heldGets()[0]);
        wait(0);
        compare(chat.records["chg-01"].profile_deleted, true);
        verify(!undo.visible, "a late answer brought undo back");
        compare(itemsWithText(chat, "已套用並確認生效。可以撤銷。").length, 0);
        compare(client.heldGets().length, 1);
        client.answer(client.heldGets()[0]);
        wait(0);
        compare(client.held.length, 0);
        verify(!undo.visible);
        verify(!!chat.records["chg-01"].card);
        // A resync alone, with an old answer out: dropped, then read again.
        const second = historyClient([historyRecord("chg-01", "prf-dev", null, false)]);
        const chat2 = createTemporaryObject(chatFactory, testCase, {client: second, tokens: tokens,
            conversation: createTemporaryObject(conversationFactory, testCase, {client: second}), width: 800, height: 700});
        chat2.conversation.events = [{type: "tool/result", data: {change_id: "chg-01"}}];
        tryVerify(() => buttonsWithText(chat2, "撤銷這項變更").length === 1 && buttonsWithText(chat2, "撤銷這項變更")[0].visible);
        second.hold = true;
        second.changeUpdated(second.summaryOf(second.records["chg-01"]));
        const kept = chat2.records["chg-01"];
        second.deleteProfile("prf-dev", true);
        second.capabilitiesReloaded();
        compare(second.heldGets().length, 1);
        second.answer(second.heldGets()[0]);
        wait(0);
        compare(chat2.records["chg-01"], kept, "a stale answer was applied after the resync");
        compare(second.heldGets().length, 1, "no read after the resync");
        second.answer(second.heldGets()[0]);
        wait(0);
        compare(chat2.records["chg-01"].profile_deleted, true);
        verify(!buttonsWithText(chat2, "撤銷這項變更")[0].visible);
        verify(kept !== chat2.records["chg-01"]);
        chat2.destroy();
        chat.destroy();
        wait(0);
    }

    // #171 R2: Core refuses to delete a Profile whose preview still counts
    // down (conflict, change_in_progress). Both Composition Centres say why,
    // and what to do, in product words.
    function test_composition_centres_explain_a_delete_refused_for_a_preview_data() {
        return [
            {tag: "built-in", url: "../shell/centers/CompositionCenter.qml"},
            {tag: "packaged", url: "../shell/providers/settings_composition/qml/CompositionCenter.qml"}
        ];
    }
    function test_composition_centres_explain_a_delete_refused_for_a_preview(data) {
        const s = setup();
        const component = Qt.createComponent(Qt.resolvedUrl(data.url));
        compare(component.status, Component.Ready, component.errorString());
        const page = createTemporaryObject(component, testCase, {client: s.client, tokens: s.tokens, width: 900, height: 900});
        verify(page !== null);
        const refusal = "「開發」還有一項正在試看的變更，現在不能刪除。請先保留或回復它，或等它自動回復後再刪除。";
        s.client.deleteError = {name: "conflict", code: -32006, message: "diagnostic",
            data: {reason: "change_in_progress"}};
        page.deleteProfile({profile_id: "prf-dev", name: "開發"});
        compare(page.notice, refusal);
        tryVerify(() => itemsWithText(page, refusal).some(item => item.visible));
        compare(page.diagnostic, "conflict");
        // Other refusals keep the client's wording.
        s.client.deleteError = {name: "conflict", code: -32006, message: "diagnostic", data: {reason: "profile_in_use"}};
        page.deleteProfile({profile_id: "prf-dev", name: "開發"});
        compare(page.notice, "generic: conflict");
        page.destroy();
        wait(0);
    }
}
