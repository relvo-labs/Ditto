import QtQuick
import QtTest
import "shell/jelly" as Jelly
TestCase {
    id: testCase
    name: "ShortcutBaselineRegressions"
    width: 1000; height: 800; visible: true; when: windowShown
    ShortcutFixture { id: client }
    Jelly.Tokens { id: tokens; appearance: ({theme: "soft-jelly-light", tokens: {}}) }
    property var page: null
    function all(item, predicate) {
        let found = [];
        for (const child of item.children) { if (predicate(child)) found.push(child); found = found.concat(all(child, predicate)); }
        return found;
    }
    function init() {
        const c = Qt.createComponent("shell/centers/PersonalizationCenter.qml");
        verify(c.status === Component.Ready, c.errorString());
        page = c.createObject(testCase, {client: client, tokens: tokens, width: 850, height: 750});
        verify(page !== null);
    }
    function cleanup() { page.destroy(); wait(0); }
    function enterDraft() {
        const settings = all(page, i => i.objectName === "shortcutSettings")[0];
        if (settings) {
            all(page, i => i.objectName === "shortcutAdd")[0].clicked();
            all(page, i => i.objectName === "shortcutCommand")[0].chosen("chat.toggle");
        }
        const field = all(page, i => i.placeholder === "例如 Super+Space" || i.objectName === "shortcutChord")[0];
        const choice = all(page, i => i.chosenCommand !== undefined || i.objectName === "shortcutCommand")[0];
        if (settings) settings.acceptCaptured("Super+K"); else field.text = "Super+K";
        if (!settings) choice.chosenCommand = "chat.toggle";
        all(page, i => i.clicked !== undefined && (i.text === "加入" || i.objectName === "shortcutSave"))[0].clicked();
        return {field: field, choice: choice, settings:settings};
    }
    function test_failed_write_keeps_input() {
        const form = enterDraft();
        client.failure({name: "preflight_rejected", message: "fixture failed write"});
        compare(form.settings ? form.settings.draftChord : form.field.text, "Super+K", "failed asynchronous save retains the typed chord");
    }
    function test_pending_interlock() {
        const form = enterDraft();
        verify(!form.field.enabled && !form.choice.enabled, "draft controls must be locked while writing");
    }
    function test_edit_discoverable() {
        verify(all(page, i => i.clicked !== undefined && /編輯/.test(i.Accessible.name)).length > 0, "existing bindings have an Edit action");
    }
}
