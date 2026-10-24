import QtQuick
import QtTest
import "shell/ui" as Ui
TestCase {
    name: "ShortcutRecorderState"
    Component { id: factory; Ui.ShortcutCaptureState {} }
    property var state: null
    property var values: []
    property var reserved: []
    function init() {
        values=[];reserved=[];
        state=createTemporaryObject(factory,this);
        state.captured.connect(chord => values.push(chord));
        state.reservedPressed.connect(chord => reserved.push(chord));
        state.begin(0);
    }
    function down(code,repeat,mods) { state.press(code+8,repeat || false,mods || 0); }
    function up(code,mods) { state.release(code+8,false,mods || 0); }
    function test_requires_real_grant() {
        down(29);down(37);up(37);up(29);compare(values.length,0);compare(state.phase,"requesting");
        state.stop("unavailable");state.grant();compare(state.phase,"unavailable");verify(!state.requested);
    }
    function test_combination_waits_for_all_releases() {
        state.grant();down(29);down(56);down(37);compare(state.candidate,"Ctrl+Alt+K");
        up(37);up(56);compare(values.length,0);up(29);compare(values,["Ctrl+Alt+K"]);verify(!state.requested);
    }
    function test_physical_y_not_layout_text_and_fkeys() {
        state.grant();down(125);down(21);up(21);up(125);compare(values,["Super+Y"]);
        state.begin(0);state.grant();down(29);down(67);up(67);up(29);compare(values[1],"Ctrl+F9");
    }
    function test_modifiers_only_and_autorepeat() {
        state.grant();down(29);down(42);up(42);up(29);compare(values.length,0);
        down(29);down(37,true);compare(state.candidate,"");down(37);down(37,true);up(37);up(29);compare(values,["Ctrl+K"]);
    }
    function test_opening_enter_and_space_are_drained_data() { return [Qt.Key_Return,Qt.Key_Enter,Qt.Key_Space].map(key => ({tag:String(key),key:key})); }
    function test_opening_enter_and_space_are_drained(row) {
        state.begin(row.key);state.grant();compare(state.phase,"arming");
        const code=row.key===Qt.Key_Space?57:row.key===Qt.Key_Enter?96:28;
        down(code);down(29);up(code,Qt.ControlModifier);compare(values.length,0);verify(state.priming);
        up(29);verify(!state.priming);down(29);down(37);up(37);up(29);compare(values,["Ctrl+K"]);
    }
    function test_modifier_held_before_start_is_not_guessed() {
        state.grant();down(37,false,Qt.ControlModifier);up(37);compare(values.length,0);compare(state.issue,"release-first");
    }
    function test_unsupported_altgr_media_and_synthetic_zero_data() { return [100,115,-8].map(code=>({tag:String(code),code:code})); }
    function test_unsupported_altgr_media_and_synthetic_zero(row) {
        state.grant();down(row.code);down(37);up(37);up(row.code);compare(values.length,0);compare(state.issue,"unsupported");
    }
    function test_two_main_keys_and_late_modifier_are_rejected() {
        state.grant();down(29);down(37);down(38);up(38);up(37);up(29);compare(values.length,0);compare(state.issue,"multiple");
        down(37);down(29);up(37);up(29);compare(values.length,0);
    }
    function test_reserved_uses_authority_metadata_and_never_captures() {
        state.reserved=["Super+L"];state.grant();down(125);down(38);up(38);up(125);
        compare(values.length,0);compare(reserved,["Super+L"]);verify(!state.requested);
    }
    function test_escape_focus_disconnect_cancel_never_regrab_data() { return ["escape","focus-lost","disconnected","compositor-cancelled","hidden","closed"].map(reason=>({tag:reason,reason:reason})); }
    function test_escape_focus_disconnect_cancel_never_regrab(row) {
        state.grant();down(29);down(37);state.stop(row.reason);up(37);up(29);state.grant();
        compare(values.length,0);verify(!state.requested);compare(state.phase,"cancelled");
    }
}
