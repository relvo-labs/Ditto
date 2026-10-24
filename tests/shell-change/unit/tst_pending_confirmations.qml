import QtQuick
import QtTest
import "../../../shell/core" as Core

TestCase {
    name: "PendingConfirmations"

    Core.DittoClient {
        id: client
        loadDesktopState: false
    }

    function test_an_ended_preview_leaves_the_countdown_table() {
        client.pendingConfirmations = {};
        client.notePending({ change_id: "legacy", confirmation: { state: "pending", deadline: "2099-01-01T00:00:00Z" } });
        client.notePending({ change_id: "other", confirmation: { state: "pending", deadline: "2099-01-01T00:00:00Z" } });
        compare(Object.keys(client.pendingConfirmations).length, 2);
        client.notePending({ change_id: "legacy", profile_deleted: true,
            confirmation: { state: "ended", at: "2026-10-24T00:00:00Z", reason: "profile_deleted" } });
        verify(!client.pendingConfirmations.legacy);
        verify(!!client.pendingConfirmations.other);
        // Duplicate notifications do not reintroduce it or clear another preview.
        client.notePending({ change_id: "legacy", confirmation: { state: "ended", reason: "profile_deleted" } });
        compare(Object.keys(client.pendingConfirmations).length, 1);
    }
}
