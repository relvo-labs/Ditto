import QtQuick

/// Mechanical check for the hot-path rule: animation must not issue requests.
/// Every request is counted and printed with a timestamp, so a verification
/// script can attribute counts to the phase of an interaction script.
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

    function reset() {
        total = 0;
        console.log("ditto-rpc-reset " + Date.now());
    }
}
