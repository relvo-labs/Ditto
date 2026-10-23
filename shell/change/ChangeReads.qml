import QtQuick

/// Reads full change records (`desktop.changes.get`) for a view that keeps
/// them: the history pages' open cards and the chat's change cards (#171).
///
/// Core answers requests concurrently, so an answer can land after newer
/// news about the same change. Per change id there is a generation: every
/// `change_updated` and every resync starts a new one (`refresh`), and an
/// answer is applied only if no generation began after its read was sent.
/// Reads of one change are coalesced: at most one in flight and one more
/// queued behind it, however many updates arrive meanwhile.
QtObject {
    id: reads

    required property var client

    /// A current record of `changeId`.
    signal read(string changeId, var record)
    /// A current read of `changeId` failed.
    signal failed(string changeId, var error)

    // Bookkeeping only; nothing binds to these.
    property var generations: ({})   // change id → current generation
    property var inFlight: ({})      // change id → generation the read was sent in
    property var queued: ({})        // change id → true: read again once the read out lands

    function generation(changeId) {
        return generations[changeId] || 0;
    }

    /// Read `changeId` unless a read of the current generation is already out.
    function request(changeId) {
        if (inFlight[changeId] !== undefined) {
            if (inFlight[changeId] !== generation(changeId)) {
                queued[changeId] = true;
            }
            return;
        }
        send(changeId);
    }

    /// Core said `changeId` changed (`change_updated`): answers to reads
    /// sent before now are stale. Read it again.
    function refresh(changeId) {
        generations[changeId] = generation(changeId) + 1;
        request(changeId);
    }

    /// After a resync: everything the view holds is read again.
    function refreshAll(changeIds) {
        for (const changeId of changeIds) {
            refresh(changeId);
        }
    }

    /// The view no longer holds `changeId` (a card closed): a read out is
    /// not applied and nothing queued is sent.
    function forget(changeId) {
        generations[changeId] = generation(changeId) + 1;
        delete queued[changeId];
    }

    function reset() {
        generations = {};
        inFlight = {};
        queued = {};
    }

    function send(changeId) {
        const sent = generation(changeId);
        inFlight[changeId] = sent;
        client.capability("desktop.changes.get", { change_id: changeId }, function (record) {
            settle(changeId, sent, record, null);
        }, function (error) {
            settle(changeId, sent, null, error);
        });
    }

    function settle(changeId, sent, record, error) {
        if (inFlight[changeId] === sent) {
            delete inFlight[changeId];
        }
        const current = sent === generation(changeId);
        if (queued[changeId]) {
            delete queued[changeId];
            send(changeId);
        }
        if (!current) {
            return;
        }
        if (error) {
            failed(changeId, error);
        } else {
            read(changeId, record);
        }
    }
}
