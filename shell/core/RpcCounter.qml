import QtQuick

/// Mechanical check for the hot-path rule: animation must not issue requests.
/// Every request is counted and printed with a timestamp, so a verification
/// script can attribute counts to the phase of an interaction script.
///
/// `mark()` records an interaction timestamp on the same clock without
/// counting it as a request (launcher open, for NFR-02 later; provider swaps,
/// for the separate frame-time segment of plan/03/04 §10).
QtObject {
    id: counter

    property int total: 0
    property bool trace: true

    function record(method) {
        total += 1;
        if (trace) {
            console.log("ditto-rpc " + Date.now() + " " + method + " total=" + total);
        }
    }

    function mark(name) {
        if (trace) {
            console.log("ditto-mark " + Date.now() + " " + name);
        }
    }

    function reset() {
        total = 0;
        console.log("ditto-rpc-reset " + Date.now());
    }
}
