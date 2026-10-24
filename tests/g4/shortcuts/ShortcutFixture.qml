import QtQuick
import "catalogues.js" as Catalogues

// Protocol-shaped controllable double. No Core/compositor; never claims a save.
QtObject {
    id: client
    property bool online: true
    property string status: "OFFSCREEN FIXTURE"
    property string locale: "zh-TW"
    property string profileId: "p-fixture"
    property string headRevision: "rev-1"
    property var bindings: [{chord: "Super+Space", command: "launcher.toggle"}, {chord: "Super+A", command: "chat.toggle"}]
    property var commands: [
        {command_id: "launcher.toggle", title_key: "command.launcher.toggle"},
        {command_id: "chat.toggle", title_key: "command.chat.toggle"},
        {command_id: "personalization.open", title_key: "command.personalization.open"},
        {command_id: "session.lock", title_key: "command.session.lock"},
        {command_id: "rescue.open", title_key: "command.rescue.open"}]
    property var calls: []
    property var success: null
    property var failure: null
    property var proposed: []
    property var last: null
    property bool readFailure: false
    property string bindingPath: "compositor"
    property var pendingConfirmations: ({})
    property var tr: ({has: key => false})
    signal profileChanged(var payload)
    signal capabilitiesReloaded()
    signal changeUpdated(var change)
    function t(source) { return locale === "en" ? (Catalogues.en.strings[source] || source) : source; }
    function key(source, args) { const cat = locale === "en" ? Catalogues.en : Catalogues.zh; return cat.keys[source] || source; }
    function errorText(error) { return t("桌面服務暫時無法使用。請稍後再試。"); }
    function diagnosticText(error) { return error.name + ": " + error.message; }
    function notePending(record) { pendingConfirmations = record.confirmation.state === "pending" ? ({ fixture: record }) : ({}); }
    function capabilityAvailable(name) { return true; }
    function info() {
        return bindings.map(b => Object.assign({}, b, {reserved: false, bound: true, conflict: false, owner: "profile"})).concat([
            {chord: "Super+L", command: "session.lock", reserved: true, bound: true, conflict: false, owner: "core"},
            {chord: "Super+Escape", command: "rescue.open", reserved: true, bound: true, conflict: false, owner: "core"}]);
    }
    function capability(method, args, ok, fail) {
        calls = calls.concat([{method: method, args: args}]);
        if (method === "desktop.profiles.get") {
            if (readFailure) { if (fail) fail({name: "unavailable", message: "fixture read failed"}); return; }
            ok({profile: {profile_id: profileId, head_revision: headRevision}, revision: {revision_id: headRevision}, document: {shortcuts: bindings}, history: []});
        } else if (method === "desktop.shortcuts.list") ok({shortcuts: info(), binding_path: bindingPath});
        else if (method === "desktop.commands.list") ok({commands: commands});
        else if (method === "desktop.appearance.get") ok({appearance: {theme: "soft-jelly-light", tokens: {}, locale: locale}, avatar: {enabled: true, scale: 1, corner: "bottom_right"}});
        else if (method === "desktop.outputs.list") ok({outputs: [{name: "Fixture-1", enabled: true}]});
        else if (method === "desktop.panels.list") ok({avatar: {output: "Fixture-1", corner: "bottom_right"}});
        else if (method === "desktop.changes.get") ok(last);
        else if (fail) fail({name: "unsupported", message: method});
    }
    function propose(ops, options, ok, fail) {
        calls = calls.concat([{method: "desktop.changes.propose", ops: ops, options: options}]);
        proposed = ops[0].after;
        success = ok;
        failure = fail;
    }
    function reply(confirmation, state) {
        last = {change_id: "cs-fixture", state: state || "committed", result: state && state !== "committed" ? "failure" : "success",
            committed_revision: "rev-2", confirmation: {state: confirmation, deadline: new Date(Date.now() + 30000).toISOString()}, items: [], card: {kind: "mixed", title_key: "change.title.mixed", items: []}};
        if (confirmation === "pending" || confirmation === "confirmed") { bindings = proposed; headRevision = "rev-2"; }
        if (confirmation === "pending") success(last); else changeUpdated(last);
    }
    function confirmChange(id, ok, fail) { reply("confirmed"); if (ok) ok(last); }
    function cancelChange(id, ok, fail) { reply("reverted", "rolled_back"); if (ok) ok(last); }
}
