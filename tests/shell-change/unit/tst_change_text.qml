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

    /// #171: Core says, at the record level, that the change's Profile was
    /// deleted since (soft delete keeps the record and the name). Switching
    /// to it is impossible and Core refuses to undo any change of it, so
    /// neither is promised and no undo button is offered.
    function deletedRecord() {
        const record = savedRecord();
        record.profile_deleted = true;
        return record;
    }

    /// The same, for a change that was applied to the desktop.
    function appliedDeletedRecord() {
        const record = deletedRecord();
        delete record.saved_only;
        return record;
    }

    function assertPromisesNothing(record) {
        for (const said of [words.stateLabel(record), words.outcomeSentence(record)]) {
            verify(said.indexOf("切換") < 0, said);
            verify(said.indexOf("可以撤銷") < 0, said);
            verify(said.indexOf("時才會套用") < 0, said);
        }
        verify(!words.undoable(record));
    }

    function test_a_saved_change_whose_profile_was_deleted_promises_no_switch_or_undo() {
        const record = deletedRecord();
        compare(words.stateLabel(record), "曾存到「開發」（已刪除）");
        compare(words.outcomeSentence(record),
                "曾存到「開發」，桌面沒有改變；這個組合已刪除，所以不會再套用，也不能撤銷。");
        compare(words.tone(record), "neutral");
        verify(words.outcomeSentence(record).indexOf("已套用") < 0);
        assertPromisesNothing(record);
    }

    function test_the_history_list_row_of_a_deleted_target_says_the_same() {
        const summary = savedSummary();
        summary.profile_deleted = true;
        compare(words.stateLabel(summary), "曾存到「開發」（已刪除）");
        compare(words.tone(summary), "neutral");
        assertPromisesNothing(summary);
    }

    function test_a_deleted_target_without_a_name_reads_the_same_way() {
        const record = deletedRecord();
        record.saved_only = { reason: "inactive_profile", profile_name: "" };
        compare(words.stateLabel(record), "曾存到另一個組合（已刪除）");
        compare(words.outcomeSentence(record),
                "曾存到另一個組合，桌面沒有改變；那個組合已刪除，所以不會再套用，也不能撤銷。");
        assertPromisesNothing(record);
    }

    /// An applied change: what happened stays true (完成), the undo
    /// promise goes.
    function test_an_applied_change_whose_profile_was_deleted_offers_no_undo() {
        const record = appliedDeletedRecord();
        compare(words.stateLabel(record), "完成");
        compare(words.outcomeSentence(record), "已套用並確認生效。這個組合之後已刪除，所以不能撤銷。");
        compare(words.tone(record), "good");
        assertPromisesNothing(record);
        const summary = savedSummary();
        delete summary.saved_only;
        summary.profile_deleted = true;
        compare(words.stateLabel(summary), "完成");
        assertPromisesNothing(summary);
    }

    /// A change waiting for the next login or normal mode applies when its
    /// Profile is active then; a deleted Profile never is again.
    function test_a_scheduled_change_whose_profile_was_deleted_promises_no_later_apply() {
        for (const reason of ["next_login", "rescue_mode"]) {
            const record = { state: "committed", result: "scheduled", hot_swap_level: "instant",
                             items: [{ status: "scheduled", reason: reason }],
                             confirmation: { state: "not_required" }, profile_deleted: true };
            compare(words.stateLabel(record), "已保存（組合已刪除）", reason);
            compare(words.outcomeSentence(record), "已保存。這個組合之後已刪除，所以不會再套用，也不能撤銷。", reason);
            verify(words.stateLabel(record).indexOf("套用") < 0, reason);
            assertPromisesNothing(record);
        }
    }

    /// Outcomes that promise neither undo nor a later apply read as before.
    function test_other_committed_outcomes_of_a_deleted_profile_read_as_before() {
        const partial = { state: "committed", result: "partial", items: [], confirmation: { state: "not_required" },
                          profile_deleted: true };
        compare(words.outcomeSentence(partial), "設定已改回，但下列項目無法還原。");
        verify(!words.undoable(partial));
        const reverted = appliedDeletedRecord();
        reverted.confirmation = { state: "reverted", by_change: "chg-2" };
        compare(words.stateLabel(reverted), "已回復");
        compare(words.outcomeSentence(reverted), "這項變更已被回復，目前是變更前的設定。");
        verify(!words.undoable(reverted));
    }

    /// The rule every undo button that shows a change record follows (the
    /// built-in and packaged history pages, the chat's change cards).
    function test_undo_is_offered_only_for_a_committed_change_core_can_undo() {
        verify(!words.undoable(null));
        verify(words.undoable(savedRecord()));
        verify(words.undoable(savedSummary()));
        const applied = savedRecord();
        delete applied.saved_only;
        verify(words.undoable(applied));
        const explicitFalse = savedRecord();
        explicitFalse.profile_deleted = false;
        verify(words.undoable(explicitFalse));
        verify(!words.undoable(deletedRecord()));
        verify(!words.undoable(appliedDeletedRecord()));
        const reverted = savedRecord();
        delete reverted.saved_only;
        reverted.confirmation = { state: "reverted", by_change: "chg-2" };
        verify(!words.undoable(reverted));
        for (const state of ["draft", "applying", "rejected", "aborted", "rolled_back", "partially_applied", "unknown"]) {
            verify(!words.undoable({ state: state, confirmation: { state: "not_required" } }), state);
        }
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
    function test_an_ended_preview_promises_no_revert_or_confirmation_action() {
        for (const record of [appliedDeletedRecord(), savedSummary()]) {
            record.confirmation = { state: "ended", at: "2026-10-24T00:00:00.000Z", reason: "profile_deleted" };
            record.profile_deleted = true;
            compare(words.stateLabel(record), "試看已結束");
            compare(words.outcomeSentence(record), "試看已結束；這個組合已刪除，所以沒有回復。");
            compare(words.tone(record), "neutral");
            verify(!words.pendingConfirmation(record));
            verify(!words.undoable(record));
            verify(words.terminal(record));
            for (const said of [words.stateLabel(record), words.outcomeSentence(record)]) {
                verify(said.indexOf("保留") < 0, said);
                verify(said.indexOf("取消") < 0, said);
                verify(said.indexOf("逾時") < 0, said);
                verify(said.indexOf("已回復") < 0, said);
            }
        }
    }

}
