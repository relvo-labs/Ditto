import QtQuick
import QtTest
import "../../../shell/change" as Change

// #169 repair 1: what the history list (summaries from desktop.changes.list)
// and the expanded change card (records from desktop.changes.get) say about a
// change. Both the built-in HistoryCenter and the packaged history page use
// this ChangeText (directly, through ChangeCard, or as Ditto.Ui.ChangeText).
// The client stub returns sources untranslated; the English catalogue is
// checked by scripts/lint-shell-i18n.mjs.
TestCase {
    id: testCase
    name: "ChangeText"

    QtObject {
        id: client
        property var tr: null
        function t(source) { return source; }
        function key(translationKey, args) { return translationKey; }
        function join(values) { return values.join(", "); }
    }

    Change.ChangeText {
        id: words
        client: client
    }

    readonly property var savedOnly: ({ reason: "inactive_profile", profile_name: "開發" })

    /// desktop.changes.get for a change saved to a Profile that is not active.
    function savedRecord() {
        return {
            change_id: "chg-1", profile_id: "prf-dev", state: "committed", result: "succeeded",
            items: [], confirmation: { state: "not_required" }, card: { kind: "appearance", items: [] },
            saved_only: savedOnly
        };
    }

    /// The same change as desktop.changes.list gives it: no items, no card.
    function savedSummary() {
        return {
            change_id: "chg-1", profile_id: "prf-dev", state: "committed", result: "succeeded",
            title_key: "change.title.appearance", confirmation: { state: "not_required" },
            saved_only: savedOnly
        };
    }

    function test_a_change_saved_to_an_inactive_profile_is_not_called_applied() {
        const record = savedRecord();
        compare(words.stateLabel(record), "已存到「開發」");
        compare(words.outcomeSentence(record),
                "已存到「開發」，桌面沒有改變；切換到這個組合時才會套用。可以撤銷。");
        compare(words.tone(record), "info");
        verify(words.outcomeSentence(record).indexOf("已套用") < 0);
        verify(words.stateLabel(record) !== "完成");
    }

    function test_the_history_list_row_says_the_same() {
        const summary = savedSummary();
        compare(words.stateLabel(summary), "已存到「開發」");
        compare(words.tone(summary), "info");
    }

    function test_without_a_profile_name_it_still_reads_as_saved_not_applied() {
        const record = savedRecord();
        record.saved_only = { reason: "inactive_profile", profile_name: "" };
        compare(words.stateLabel(record), "已存到另一個組合");
        compare(words.outcomeSentence(record),
                "已存到另一個組合，桌面沒有改變；切換到那個組合時才會套用。可以撤銷。");
    }

    function test_a_change_applied_to_the_desktop_reads_as_before() {
        const record = savedRecord();
        delete record.saved_only;
        compare(words.stateLabel(record), "完成");
        compare(words.outcomeSentence(record), "已套用並確認生效。可以撤銷。");
        compare(words.tone(record), "good");
        const summary = savedSummary();
        delete summary.saved_only;
        compare(words.stateLabel(summary), "完成");
    }

    function test_other_outcomes_are_not_affected_by_the_field() {
        // Only a committed change can carry saved_only; the other wording
        // stays keyed on state and result.
        const scheduled = { state: "committed", result: "scheduled", hot_swap_level: "session_restart",
                            items: [{ status: "scheduled", reason: "next_login" }],
                            confirmation: { state: "not_required" } };
        compare(words.stateLabel(scheduled), "待下次登入套用");
        const rejected = { state: "rejected", result: "failed", confirmation: { state: "not_required" } };
        compare(words.stateLabel(rejected), "未通過檢查");
    }
}
