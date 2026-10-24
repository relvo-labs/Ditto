import QtQuick
import Quickshell
import "jelly"
import "chat" as Chat

ShellRoot {
    id: root
    property var heldPage: null
    property var component: null
    readonly property bool pluginCase: Quickshell.env("DITTO_TEST_PAGE_ID") === "plugins"
    readonly property var pluginManifest: pluginCase ? JSON.parse(Quickshell.env("DITTO_TEST_PLUGIN_MANIFEST")) : null
    function pluginSummary() {
        return {package_id: pluginManifest.id, version: pluginManifest.version,
            sha256: Quickshell.env("DITTO_TEST_PLUGIN_SHA256"), source: pluginManifest.source,
            name: pluginManifest.name, author: pluginManifest.author, license: pluginManifest.license,
            plugin_kind: pluginManifest.plugin_kind, host_kind: pluginManifest.host_kind,
            trust_level: pluginManifest.trust_level, installed_at: "2026-10-24T00:00:00Z", referenced_by: 1};
    }
    function pluginPackages() {
        return [pluginSummary(), Object.assign({}, pluginSummary(), {package_id: "ditto.fixture.other", name: {"zh-TW": "其他元件", en: "Other"}, referenced_by: 0})];
    }
    function pluginEntries() {
        // EntryStatus has no name or config field: use the actual wire shape.
        return [{entry_id: "plugin-center-entry", package: pluginManifest.id, version: pluginManifest.version,
            host: "qml", slot: "ui.settings_page", disabled: false, state: {kind: "active"},
            started_reason: "profile", trust_note_key: "trust.same_host_no_isolation.qml"}];
    }
    Tokens { id: tokens; readsSystemPreference: false }
    QtObject {
        id: client
        property var capabilityCalls: []
        property bool online: true
        property var tr: QtObject {
            property string language: "zh-TW"
            function slotName(slot) { return slot; }
            function packageName(id) { return id; }
            function has(key) { return false; }
            function localized(value) {
                if (value && typeof value === "object") return value[language] || value["zh-TW"] || value.en || "";
                return value ? String(value) : "";
            }
        }
        signal capabilitiesReloaded()
        signal changeUpdated(var change)
        signal profileChanged(var profile)
        signal panelsReported(var panels)
        signal jobUpdated(var job)
        signal disconnected()
        function watchTopics(topics, event, resync, ready, fail) {}
        function t(source) { return source; }
        function key(source, args) { return source; }
        function join(values) { return values.join(", "); }
        function capability(name, args, done, fail) {
            capabilityCalls = capabilityCalls.concat([name]);
            if (name === "agent.settings.describe") done({enabled: false, revision: "fixture", provider: "codex-app-server", approval_mode: "ask"});
            else if (name === "agent.sessions.list") done({sessions: []});
            else if (name === "desktop.appearance.get") done({appearance: {theme: "soft-jelly-light", tokens: {}}, avatar: {enabled: false}});
            else if (name === "desktop.shortcuts.list") done({shortcuts: []});
            else if (name === "desktop.commands.list") done({commands: []});
            else if (name === "desktop.outputs.list") done({outputs: []});
            else if (name === "desktop.panels.list") done({avatar: null});
            else if (name === "desktop.changes.list") done({changes: []});
            else if (name === "desktop.profiles.list") done({profiles: []});
            else if (name === "desktop.profiles.get") done({profile: {profile_id: "test", name: "Test"}, document: {entries: [], slots: {}}, history: []});
            else if (name === "desktop.plugins.list") done(root.pluginCase
                ? {entries: root.pluginEntries(), packages: root.pluginPackages()} : {entries: [], packages: []});
            else if (name === "desktop.plugins.get" && root.pluginCase) done({manifest: Object.assign({}, root.pluginManifest,
                args.package_id === root.pluginManifest.id
                    ? {description: {"zh-TW": "管理桌面元件", en: "Manage desktop components"}}
                    : {id: args.package_id, name: {"zh-TW": "其他元件", en: "Other"}, description: "Other"})});
            else if (name === "desktop.layout.get") done({available: []});
            else if (name === "desktop.plugins.diagnostics") done({entries: [], host: null});
            else if (name === "desktop.permissions.list") done({grants: []});
            else if (name === "desktop.plugins.development.list") done({artifacts: []});
            else if (name === "desktop.jobs.list") done({jobs: []});
        }
    }
    Chat.ConversationState { id: conversation; client: client }
    Item { id: visualParent; width: 800; height: 600 }
    function named(item, name) {
        if (item.objectName === name) return item;
        for (const child of item.children || []) {
            const found = named(child, name);
            if (found) return found;
        }
        return null;
    }
    function checkPluginSearch() {
        const field = named(heldPage, "pluginSearchField");
        const rows = named(heldPage, "installedPluginRows");
        const empty = named(heldPage, "pluginSearchEmpty");
        if (!field || !rows || !empty) return false;
        const initial = JSON.stringify([heldPage.packages, heldPage.entries]);
        const calls = client.capabilityCalls.length;
        const checks = [
            {query: "DITTO.SETTINGS.PLUGINS", count: 1},
            {query: "PLUGIN-CENTER-ENTRY", count: 1},
            {query: "管理桌面", count: 1},
            {query: "<b>不存在</b>", count: 0},
            {query: "PLUGIN CENTER", count: 0},
            // Do not replace the query here: the existing binding must react.
            {language: "en", count: 1},
            {language: "zh-TW", count: 0},
            {query: "", count: 2}
        ];
        for (const check of checks) {
            if (check.language) client.tr.language = check.language;
            else field.text = check.query;
            if (heldPage.filteredPackages.length !== check.count || rows.count !== check.count
                    || empty.visible !== (check.count === 0) || empty.textFormat !== Text.PlainText) {
                console.log("REAL_PLUGIN_SEARCH_FAILED " + JSON.stringify(check));
                return false;
            }
        }
        if (client.capabilityCalls.length !== calls || JSON.stringify([heldPage.packages, heldPage.entries]) !== initial) return false;
        console.log("REAL_PLUGIN_SEARCH_READY root:/sdk/Ditto/Ui " + pluginManifest.id + "@" + pluginManifest.version + " checks=" + checks.length);
        return true;
    }
    Component.onCompleted: {
        const pageUrl = Quickshell.env("DITTO_TEST_PAGE_URL");
        const pageId = Quickshell.env("DITTO_TEST_PAGE_ID");
        if (!pageUrl || pageUrl.indexOf("file://") !== 0) {
            console.log("REAL_PAGE_FAILED missing absolute package URL");
            return;
        }
        console.log("REAL_PAGE_SOURCE " + pageUrl);
        component = Qt.createComponent(pageUrl);
        if (component.status !== Component.Ready) {
            console.log("REAL_PAGE_FAILED " + component.errorString());
            return;
        }
        heldPage = component.createObject(visualParent, {client: client, tokens: tokens,
            config: {externalStore: true}, pageId: pageId, entryId: "real-" + pageId});
        if (heldPage && heldPage.aiSettings !== undefined) heldPage.aiSettings = conversation.aiSettings;
        const expectedCalls = {
            history: ["desktop.changes.list"],
            composition: ["desktop.profiles.list", "desktop.profiles.get", "desktop.plugins.list", "desktop.layout.get"],
            plugins: ["desktop.plugins.list", "desktop.plugins.get", "desktop.plugins.get", "desktop.plugins.diagnostics", "desktop.permissions.list", "desktop.plugins.development.list", "desktop.jobs.list"],
            personalization: ["desktop.appearance.get", "desktop.profiles.get", "desktop.shortcuts.list", "desktop.commands.list", "desktop.outputs.list", "desktop.panels.list"],
            ai: ["agent.settings.describe", "agent.sessions.list"]
        };
        const expected = expectedCalls[pageId];
        const stateRead = heldPage && (pageId === "history" ? heldPage.changes.length === 0
            : pageId === "composition" ? heldPage.active.profile.profile_id === "test" && heldPage.profiles.length === 0
            : pageId === "personalization" ? heldPage.appearance.theme === "soft-jelly-light" && heldPage.outputs.length === 0 && heldPage.providers === undefined
            : pageId === "ai" ? heldPage.aiSettings === conversation.aiSettings && heldPage.settings.enabled === false
                && heldPage.conversation === undefined && heldPage.aiSettings.draft === undefined && heldPage.aiSettings.sessions === undefined
            : heldPage.packages.length === 2 && heldPage.entries.length === 1 && heldPage.grants.length === 0 && checkPluginSearch());
        if (heldPage && heldPage.pageId === pageId && heldPage.entryId === "real-" + pageId
                && heldPage.config.externalStore === true && heldPage.client === client && heldPage.tokens === tokens
                && heldPage.flickable === heldPage && stateRead && expected
                && JSON.stringify(client.capabilityCalls.slice().sort()) === JSON.stringify(expected.slice().sort())) {
            console.log("REAL_PAGE_READY root:/sdk/Ditto/Ui packaged " + pageId);
        } else {
            console.log("REAL_PAGE_FAILED " + component.errorString());
        }
    }
    Timer { interval: 100; running: true; onTriggered: Qt.quit() }
}
