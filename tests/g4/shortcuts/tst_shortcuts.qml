import QtQuick
import QtTest
import "shell/jelly" as Jelly
TestCase {
    id: testCase
    name: "ShortcutWorkflows"
    width: 1000; height: 1000; visible: true; when: windowShown
    ShortcutFixture { id: client }
    Jelly.Tokens { id: tokens; appearance: ({theme: "soft-jelly-light", tokens: {}}) }
    property var page: null
    property var settings: null
    function all(item, predicate) {
        let found = [];
        for (const child of item.children) { if (predicate(child)) found.push(child); found = found.concat(all(child, predicate)); }
        return found;
    }
    function named(name) { return all(settings, i => i.objectName === name)[0]; }
    function init() {
        client.bindings = [{chord: "Super+Space", command: "launcher.toggle"}, {chord: "Super+A", command: "chat.toggle"}];
        client.headRevision = "rev-1"; client.profileId = "p-fixture"; client.readFailure = false; client.calls = [];
        const c = Qt.createComponent("shell/centers/PersonalizationCenter.qml");
        verify(c.status === Component.Ready, c.errorString());
        page = c.createObject(testCase, {client: client, tokens: tokens, width: 850, height: 950});
        verify(page !== null);
        settings = all(page, i => i.objectName === "shortcutSettings")[0];
        verify(settings !== undefined);
    }
    function cleanup() { page.destroy(); wait(0); }
    function edit() {
        const button = all(settings, i => i.clicked !== undefined && i.Accessible.name === client.t("編輯 %1").arg(settings.title("launcher.toggle")))[0];
        page.contentY = settings.y;
        settings.begin(0, button);
        settings.acceptCaptured("Super+K");
    }
    function test_edit_cancel_focus_and_snapshot() {
        edit(); compare(settings.draftChord, "Super+K");
        tryVerify(() => named("shortcutChord").activeFocus);
        keyClick(Qt.Key_Escape);
        compare(settings.editing, -2); compare(client.bindings[0].chord, "Super+Space");
        compare(client.calls.filter(c => c.method === "desktop.changes.propose").length, 0);
        verify(all(settings, i => i.activeFocus && i.clicked !== undefined).length === 1, "focus returned to edit");
    }
    function test_confirmed_readback_clears_only_after_keep() {
        edit(); named("shortcutSave").clicked();
        const call = client.calls.find(c => c.method === "desktop.changes.propose");
        compare(call.ops[0].path, "/shortcuts"); compare(call.options.baseRevision, "rev-1");
        compare(call.options.profileId, "p-fixture"); compare(call.ops[0].before[0].chord, "Super+Space");
        compare(call.ops[0].after[0].chord, "Super+K");
        client.reply("pending"); verify(settings.locked); compare(settings.draftChord, "Super+K");
        compare(settings.info[0].chord, "Super+K", "the active trial is read back while its draft stays locked");
        wait(0);
        compare(named("shortcutChord").text, settings.keyLabel("Super+K"));
        verify(named("shortcutChord").visible && named("shortcutChord").height > 0, "the pending draft remains visible");
        client.reply("confirmed");
        compare(settings.editing, -2); compare(settings.draftChord, ""); compare(settings.bindings[0].chord, "Super+K");
        verify(client.calls.filter(c => c.method === "desktop.profiles.get").length >= 2, "save read back from authority");
    }
    function test_failed_readback_and_mismatch_keep_draft() {
        edit(); settings.save(); client.reply("pending");
        client.readFailure = true; client.reply("confirmed");
        compare(settings.draftChord, "Super+K"); verify(settings.uncertain);
        client.readFailure = false; client.headRevision = "rev-other";
        settings.reconcile(); compare(settings.draftChord, "Super+K"); verify(settings.uncertain);
        client.headRevision = "rev-2"; settings.reconcile(); compare(settings.draftChord, "");
    }
    function test_revert_keeps_draft_and_unlocks() {
        edit(); settings.save(); client.reply("pending");
        client.bindings = settings.draftBefore; client.headRevision = "rev-1";
        client.reply("reverted", "rolled_back");
        compare(settings.draftChord, "Super+K"); verify(!settings.locked); compare(settings.bindings[0].chord, "Super+Space");
    }
    // Actual key events open the UI, not a typed chord. The no-grant fixture
    // must remain unavailable. acceptCaptured only injects the result at the
    // transaction seam; native recorder recognition has separate evidence.
    function test_keyboard_create_with_real_key_events() {
        page.contentY = settings.y;
        named("shortcutAdd").forceActiveFocus(); keyClick(Qt.Key_Return);
        const option=all(named("shortcutCommand"), i => i.activeFocusOnTab && i.Accessible.name === settings.title("launcher.toggle"))[0];
        option.forceActiveFocus(); keyClick(Qt.Key_Right); keyClick(Qt.Key_Space);
        compare(settings.draftCommand,"chat.toggle");
        named("shortcutChord").forceActiveFocus(); keyClick(Qt.Key_Return);
        verify(settings.captureOpen);compare(settings.draftChord,"");
        settings.cancelRecording();tryCompare(settings,"captureOpen",false);
        settings.acceptCaptured("Ctrl+Alt+K");
        named("shortcutSave").forceActiveFocus();keyClick(Qt.Key_Return);
        compare(client.proposed[2].chord,"Ctrl+Alt+K");
        client.failure({name:"preflight_rejected",message:"fixture failure"});
        compare(settings.draftChord,"Ctrl+Alt+K");
    }
    function test_late_event_does_not_clear_a_new_draft() {
        edit(); settings.save(); client.reply("pending"); client.reply("confirmed");
        settings.begin(-1, named("shortcutAdd"));
        settings.acceptCaptured("Super+M");
        client.changeUpdated(client.last);
        compare(settings.draftChord, "Super+M"); compare(settings.editing, -1);
    }
    function test_conflicts_reserved_and_duplicate() {
        edit(); settings.acceptCaptured("Super+L");
        verify(settings.conflict.indexOf("系統保留") >= 0); verify(!named("shortcutSave").enabled);
        settings.acceptCaptured("Super+A");
        verify(settings.conflict.indexOf("已用於") >= 0); verify(!named("shortcutSave").enabled);
        compare(client.calls.filter(c => c.method === "desktop.changes.propose").length, 0);
    }
    function test_create_pending_failed_and_retry() {
        named("shortcutAdd").clicked(); named("shortcutCommand").chosen("chat.toggle"); settings.acceptCaptured("Super+K");
        settings.save(); settings.save();
        compare(client.calls.filter(c => c.method === "desktop.changes.propose").length, 1);
        verify(!named("shortcutChord").enabled); verify(!named("shortcutCancel").enabled);
        client.failure({name: "preflight_rejected", message: "fixture rejection"});
        compare(settings.draftChord, "Super+K"); verify(!settings.locked);
        settings.save(); client.reply("pending"); client.reply("confirmed"); compare(settings.bindings.length, 3);
    }
    function test_unknown_does_not_resubmit() {
        edit(); settings.save(); client.failure({name: "timeout", message: "no answer", data: {outcome: "unknown"}});
        compare(settings.draftChord, "Super+K"); verify(settings.locked); settings.save();
        compare(client.calls.filter(c => c.method === "desktop.changes.propose").length, 1);
    }
    function test_stale_draft_does_not_adopt_new_base() {
        edit(); client.headRevision = "rev-other"; client.profileChanged({active: true}); settings.save();
        const call = client.calls.find(c => c.method === "desktop.changes.propose");
        compare(call.options.baseRevision, "rev-1"); compare(call.ops[0].before[0].chord, "Super+Space");
    }
    function test_remove_uses_same_confirmation() {
        edit(); settings.remove(); compare(client.proposed.length, 1); client.reply("pending");
        compare(settings.draftChord, "Super+K"); verify(settings.locked); client.reply("confirmed"); compare(settings.editing, -2);
    }
    function test_narrow_locale_and_provider_data() {
        const rows = [];
        for (const locale of ["zh-TW", "en"]) for (const theme of ["soft-jelly", "soft-jelly-light"]) rows.push({tag: locale + theme, locale: locale, theme: theme});
        return rows;
    }
    function test_narrow_locale_and_provider(row) {
        client.locale = row.locale; tokens.appearance = {theme: row.theme, tokens: {}};
        page.width = 390; edit(); waitForRendering(page);
        for (const control of all(settings, i => i.visible && (i.objectName === "shortcutChord" || i.objectName === "shortcutCommand" || i.clicked !== undefined))) {
            const p = control.mapToItem(settings, 0, 0);
            verify(p.x >= 0 && p.x + control.width <= settings.width + 1, control.objectName + " stays inside shortcut width");
        }
        const c = Qt.createComponent("shell/providers/settings_personalization/qml/PersonalizationCenter.qml");
        verify(c.status === Component.Ready, c.errorString());
        const provider = c.createObject(testCase, {client: client, tokens: tokens, width: 390, height: 900});
        verify(provider !== null); compare(all(provider, i => i.objectName === "shortcutSettings").length, 1);
        provider.destroy(); wait(0); client.locale = "zh-TW";
    }
}
