import QtQuick
import QtTest
import "../../../shell/change" as Change

// #171 R2: ChangeReads reads full change records for a view that keeps them.
// Answers come back in whatever order Core sends them, so an answer to a
// read sent before a newer `change_updated` (or a resync) must not replace
// what that update said; reads of one change are coalesced. The client here
// holds every desktop.changes.get until the test answers it.
TestCase {
    id: testCase
    name: "ChangeReads"

    QtObject {
        id: client
        property var held: []
        function capability(name, args, done, fail) {
            held = held.concat([{ name: name, changeId: args.change_id, done: done, fail: fail }]);
        }
        /// Answer the held read `index` with `value` (or fail it).
        function answer(index, value, failed) {
            const call = held[index];
            held = held.filter((_, i) => i !== index);
            if (failed) call.fail(value);
            else call.done(value);
        }
    }

    Change.ChangeReads {
        id: reads
        client: client
        property var got: []
        property var errors: []
        onRead: function (changeId, record) { got = got.concat([{ changeId: changeId, record: record }]); }
        onFailed: function (changeId, error) { errors = errors.concat([{ changeId: changeId, error: error }]); }
    }

    function init() {
        client.held = [];
        reads.got = [];
        reads.errors = [];
        reads.reset();
    }

    function test_an_answer_is_applied_when_nothing_newer_arrived() {
        reads.request("chg-1");
        compare(client.held.length, 1);
        compare(client.held[0].name, "desktop.changes.get");
        client.answer(0, { change_id: "chg-1", v: 1 });
        compare(reads.got.length, 1);
        compare(reads.got[0].record.v, 1);
    }

    function test_an_answer_sent_before_an_update_is_dropped_and_read_again() {
        reads.request("chg-1");
        // change_updated arrives while the first read is out: a second one is
        // queued, not sent.
        reads.refresh("chg-1");
        reads.refresh("chg-1");
        reads.refresh("chg-1");
        compare(client.held.length, 1, "overlapping reads were not coalesced");
        // The late, older answer (taken before the Profile was deleted).
        client.answer(0, { change_id: "chg-1", profile_deleted: undefined });
        compare(reads.got.length, 0, "a stale answer was applied");
        // Exactly one more read went out, after the update.
        compare(client.held.length, 1);
        client.answer(0, { change_id: "chg-1", profile_deleted: true });
        compare(reads.got.length, 1);
        compare(reads.got[0].record.profile_deleted, true);
        compare(client.held.length, 0);
    }

    function test_a_resync_makes_every_read_out_stale() {
        reads.request("chg-1");
        reads.request("chg-2");
        compare(client.held.length, 2);
        reads.refreshAll();
        compare(client.held.length, 2, "a resync sent reads beside those already out");
        client.answer(1, { change_id: "chg-2", v: "old" });
        client.answer(0, { change_id: "chg-1", v: "old" });
        compare(reads.got.length, 0, "a stale answer was applied after a resync");
        compare(client.held.length, 2);
        client.answer(0, { change_id: client.held[0].changeId, v: "new" });
        client.answer(0, { change_id: client.held[0].changeId, v: "new" });
        compare(reads.got.length, 2);
        verify(reads.got.every(item => item.record.v === "new"));
    }

    /// A change is held from its first request, before any answer: an
    /// update or a resync then makes that first answer stale too.
    function test_a_first_read_still_out_is_held_and_made_stale() {
        verify(!reads.holds("chg-1"));
        reads.request("chg-1");
        verify(reads.holds("chg-1"));
        compare(reads.heldIds(), ["chg-1"]);
        reads.refreshAll();
        compare(client.held.length, 1);
        client.answer(0, { change_id: "chg-1", v: "old" });
        compare(reads.got.length, 0, "the first answer was applied after a resync");
        compare(client.held.length, 1, "exactly one more read");
        client.answer(0, { change_id: "chg-1", v: "new" });
        compare(reads.got.length, 1);
        compare(reads.got[0].record.v, "new");
        reads.forget("chg-1");
        verify(!reads.holds("chg-1"));
        compare(reads.heldIds().length, 0);
    }

    function test_joining_a_current_read_sends_nothing_more() {
        reads.request("chg-1");
        reads.request("chg-1");
        compare(client.held.length, 1);
        client.answer(0, { change_id: "chg-1" });
        compare(client.held.length, 0);
        compare(reads.got.length, 1);
    }

    function test_a_forgotten_read_is_neither_applied_nor_repeated() {
        reads.request("chg-1");
        reads.refresh("chg-1");
        reads.forget("chg-1");
        client.answer(0, { change_id: "chg-1" });
        compare(reads.got.length, 0);
        compare(client.held.length, 0);
    }

    /// #171 R4: when the view's list is replaced, the changes it no longer
    /// shows are released: their answers are not applied and a resync reads
    /// only what is still held.
    function test_retain_releases_the_changes_no_longer_shown() {
        reads.request("chg-1");
        reads.request("chg-2");
        reads.request("chg-3");
        client.answer(0, { change_id: "chg-1" });
        compare(reads.got.length, 1);
        compare(reads.retain(["chg-1", "chg-9"]), ["chg-2", "chg-3"]);
        compare(reads.heldIds(), ["chg-1"]);
        verify(!reads.holds("chg-2") && !reads.holds("chg-3"));
        // Their answers land late: not applied, nothing read again.
        client.answer(0, { change_id: client.held[0].changeId });
        client.answer(0, { change_id: client.held[0].changeId });
        compare(reads.got.length, 1);
        compare(client.held.length, 0);
        reads.refreshAll();
        compare(client.held.map(call => call.changeId), ["chg-1"]);
        compare(reads.retain(["chg-1"]), []);
    }

    /// What is kept per change stays bounded by the changes held or with a
    /// read still out, however many come and go.
    function test_a_forgotten_change_keeps_nothing_once_settled() {
        for (let n = 0; n < 50; ++n) {
            reads.request("chg-" + n);
        }
        reads.retain([]);
        compare(reads.heldIds().length, 0);
        while (client.held.length > 0) {
            client.answer(0, { change_id: client.held[0].changeId });
        }
        compare(reads.got.length, 0);
        compare(Object.keys(reads.generations).length, 0);
        compare(Object.keys(reads.inFlight).length, 0);
        compare(Object.keys(reads.queued).length, 0);
        // Forgotten, then requested again while the old read is still out:
        // the old answer is dropped and the new read applies.
        reads.request("chg-1");
        reads.forget("chg-1");
        reads.request("chg-1");
        compare(client.held.length, 1);
        client.answer(0, { change_id: "chg-1", v: "old" });
        compare(reads.got.length, 0, "an answer from before the forget was applied");
        compare(client.held.length, 1);
        client.answer(0, { change_id: "chg-1", v: "new" });
        compare(reads.got.length, 1);
        compare(reads.got[0].record.v, "new");
        // Forgotten with nothing out: nothing kept.
        reads.forget("chg-1");
        compare(Object.keys(reads.generations).length, 0);
    }

    function test_only_a_current_failure_is_reported() {
        reads.request("chg-1");
        reads.refresh("chg-1");
        client.answer(0, { name: "timeout" }, true);
        compare(reads.errors.length, 0, "a stale failure was reported");
        client.answer(0, { name: "not_found" }, true);
        compare(reads.errors.length, 1);
        compare(reads.errors[0].error.name, "not_found");
    }
}
