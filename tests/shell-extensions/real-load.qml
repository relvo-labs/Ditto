import QtQuick
import Quickshell
import "jelly"

ShellRoot {
    id: root
    property var heldPage: null
    property var component: null
    Tokens { id: tokens; readsSystemPreference: false }
    QtObject {
        id: client
        property var capabilityCalls: []
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
    Item { id: visualParent; width: 800; height: 600 }
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
        const expectedCalls = {
            history: ["desktop.changes.list"],
            composition: ["desktop.profiles.list", "desktop.profiles.get", "desktop.plugins.list", "desktop.layout.get"],
            plugins: ["desktop.plugins.list", "desktop.plugins.diagnostics", "desktop.permissions.list", "desktop.plugins.development.list", "desktop.jobs.list"]
        };
        const expected = expectedCalls[pageId];
        const stateRead = heldPage && (pageId === "history" ? heldPage.changes.length === 0
            : pageId === "composition" ? heldPage.active.profile.profile_id === "test" && heldPage.profiles.length === 0
            : heldPage.packages.length === 0 && heldPage.grants.length === 0);
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
