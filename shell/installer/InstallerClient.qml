pragma ComponentBehavior: Bound
import QtQuick
import Quickshell.Io

// Projection of the root installer backend. The backend decides and writes;
// this item only shows its state and sends the fixed actions with the opaque
// tokens it was given. No paths, devices or commands are ever sent.
Item {
    id: client
    property string socketPath: "/run/ditto-installer/backend.sock"
    property alias transport: socket
    property string medium: "searching"
    property string phase: "starting"
    property string notice: ""
    property var disks: []
    property var confirmation: null
    property var progress: ({stage: "", done: 0, total: 0})
    property var result: null
    property string lastError: ""
    property bool lost: false
    property bool rebooting: false
    property bool everConnected: false
    property var pending: []
    // "" | "pending" | "accepted" | "refused" (backend: too late, the partition table is being written)
    property string cancelStatus: ""
    readonly property int percent: progress && progress.total > 0
        ? Math.min(100, Math.floor(100 * progress.done / progress.total)) : 0

    function send(action, fields) {
        if (lost || !socket.connected) return false;
        pending = pending.concat([action]);
        socket.write(JSON.stringify(Object.assign({action: action}, fields || {})) + "\n");
        socket.flush();
        return true;
    }
    function refresh() { send("list"); }
    function select(token) { if (typeof token === "string" && token.length > 0) send("select", {token: token}); }
    function back() { if (phase === "confirming") send("back"); }
    function confirm() { if (phase === "confirming" && confirmation) send("confirm", {token: confirmation.token}); }
    function cancel() {
        if (phase === "installing" && cancelStatus !== "") return;
        if (send("cancel") && phase === "installing") cancelStatus = "pending";
    }
    function reboot() { send("reboot"); }
    function poll() { if (pending.length === 0) send("state"); }
    // The backend starts writing before it answers "confirm": once confirm is sent
    // and unanswered, or the write is running, a lost backend means an unknown result.
    function writeMayHaveStarted() { return phase === "installing" || pending.indexOf("confirm") >= 0; }
    function markLost() {
        lost = true;
        pending = [];
        socket.connected = false;
    }
    function consume(line) {
        if (line.length === 0) return;
        let reply;
        try { reply = JSON.parse(line); } catch (e) { markLost(); return; }
        const action = pending.length > 0 ? pending[0] : "";
        pending = pending.slice(1);
        if (reply.ok !== true) {
            lastError = typeof reply.error === "string" ? reply.error : "internal_error";
            if (lastError === "peer_rejected") { markLost(); return; }
            if (action === "cancel" && cancelStatus === "pending")
                cancelStatus = lastError === "committing" ? "refused" : "";
            if (action === "select" || action === "confirm") { confirmation = null; refresh(); }
            return;
        }
        lastError = "";
        if (action === "state") {
            const before = phase;
            medium = String(reply.medium);
            phase = String(reply.state);
            notice = reply.notice || "";
            progress = reply.progress || ({stage: "", done: 0, total: 0});
            result = reply.result || null;
            rebooting = reply.rebooting === true;
            if (phase === "listing" && before !== "listing" && before !== "confirming") refresh();
            if (phase !== "confirming") confirmation = null;
            if (phase !== "installing") cancelStatus = "";
        } else if (action === "list") {
            disks = reply.disks || [];
        } else if (action === "select") {
            confirmation = {token: reply.confirm_token, disk: reply.disk};
            phase = "confirming";
        } else if (action === "back" || (action === "cancel" && reply.state === "listing")) {
            confirmation = null;
            phase = "listing";
            refresh();
        } else if (action === "cancel") {
            if (cancelStatus === "pending") cancelStatus = "accepted";
        } else if (action === "confirm") {
            confirmation = null;
            phase = "installing";
        } else if (action === "reboot") {
            rebooting = true;
        }
    }
    Socket {
        id: socket
        objectName: "installerBackend"
        path: client.socketPath
        connected: true
        onConnectionStateChanged: {
            if (connected) {
                client.everConnected = true;
                client.pending = [];
                client.poll();
            } else if (client.everConnected && (client.writeMayHaveStarted() || client.rebooting)) {
                // The result of an interrupted (or possibly started) write is unknown;
                // never reconnect into a guess.
                client.markLost();
            }
        }
        onError: () => { if (client.writeMayHaveStarted()) client.markLost(); }
        parser: SplitParser { splitMarker: "\n"; onRead: data => client.consume(data) }
    }
    Timer {
        // Polling is bounded and only runs while this screen exists: the backend
        // has no push channel, and progress must reflect its real stage.
        objectName: "installerPoll"
        interval: 500
        repeat: true
        running: !client.lost
        onTriggered: {
            if (socket.connected) client.poll();
            else if (!client.lost) socket.connected = true;
        }
    }
}
