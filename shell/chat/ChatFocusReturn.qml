import QtQuick

/// Shell UI transient state only. If the person switched applications while
/// chat stayed open, closing chat must not focus the original application.
QtObject {
    id: policy
    required property var client
    property bool enabled: true
    property string returnWindow: ""
    property string lastFocusedApplication: ""
    property bool chatOpen: false
    property bool blocked: false

    function canRestore() {
        return enabled && !chatOpen && !blocked && returnWindow.length > 0
            && returnWindow === lastFocusedApplication;
    }
    function restore() {
        if (!canRestore()) return;
        const id = returnWindow;
        Qt.callLater(() => {
            // Check again: focus, approvals or another open can change before
            // the old layer surface has disappeared and this callback runs.
            if (policy.returnWindow === id && policy.canRestore()
                && policy.client.windows.some(window => window.id === id)) {
                policy.client.focusWindow(id);
            }
        });
    }
}
