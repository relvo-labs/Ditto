import QtQuick
import Quickshell
import Quickshell.Io

/// The shell's only path to the desktop. Every window and workspace value comes
/// from a snapshot plus the events that follow it; nothing is polled, and no
/// component talks to the compositor directly.
QtObject {
    id: client

    readonly property string socketPath: Quickshell.env("DITTO_CORE_SOCKET")
        || ((Quickshell.env("DITTO_RUNTIME_DIR")
            || (Quickshell.env("XDG_RUNTIME_DIR") + "/ditto")) + "/core.sock")
    readonly property string protocolVersion: "0.1.0"

    property bool online: false
    /// Product-language state for the surfaces; diagnostics go to the log.
    property string status: "桌面服務連線中"
    property var capabilities: ({})
    property var windows: []
    property var workspaces: []
    property var outputs: []
    property string subscriptionId: ""
    property int seq: 0
    property var counter: null

    signal changed()

    property string token: ""
    property int nextId: 0
    property var pending: ({})
    property bool handshakeDone: false
    property bool identityRefused: false

    function capabilityAvailable(capabilityId) {
        const descriptor = capabilities[capabilityId];
        if (!descriptor) {
            return false;
        }
        if (descriptor.availability.kind === "always") {
            return true;
        }
        return descriptor.availability.available === true;
    }

    function call(method, params, onResult, onError) {
        if (!socket.connected || (!handshakeDone && method !== "core.handshake")) {
            if (onError) {
                onError({ name: "unavailable", message: "桌面服務未連線" });
            }
            return;
        }
        nextId += 1;
        const id = "shell-" + nextId;
        const body = { jsonrpc: "2.0", id: id, method: method, params: params };
        pending[id] = { resolve: onResult, reject: onError, method: method };
        if (counter) {
            counter.record(method);
        }
        socket.write(JSON.stringify(body) + "\n");
        if (socket.flush) {
            socket.flush();
        }
    }

    function capability(capabilityId, params, onResult, onError) {
        const body = params ? JSON.parse(JSON.stringify(params)) : {};
        body._meta = { protocol_version: protocolVersion, deadline_ms: 2000 };
        call(capabilityId, body, onResult, onError);
    }

    function focusWindow(windowId) {
        capability("desktop.windows.focus", { window_id: windowId }, null, function (error) {
            console.log("ditto-shell focus refused: " + error.name + " " + error.message);
        });
    }

    function activateWorkspace(workspaceId) {
        capability("desktop.workspaces.activate", { workspace_id: workspaceId }, null, function (error) {
            console.log("ditto-shell workspace refused: " + error.name + " " + error.message);
        });
    }

    function closeWindow(windowId) {
        capability("desktop.windows.close_request", { window_id: windowId }, null, function (error) {
            console.log("ditto-shell close refused: " + error.name + " " + error.message);
        });
    }

    function handshake() {
        const params = {
            protocol_version: protocolVersion,
            client: {
                kind: Quickshell.env("DITTO_CLIENT_KIND") || "quickshell",
                version: Quickshell.env("DITTO_CLIENT_VERSION") || "0.1.0"
            },
            auth: { token: token }
        };
        call("core.handshake", params, function () {
            handshakeDone = true;
            loadCatalog();
            subscribe();
        }, function (error) {
            identityRefused = error.name === "identity_rejected";
            status = identityRefused
                ? "桌面服務未連線，需重新啟動工作階段"
                : "桌面服務未連線";
            console.log("ditto-shell handshake refused: " + error.name + " " + error.message);
            socket.connected = false;
        });
    }

    function loadCatalog() {
        capability("desktop.capabilities.list", {}, function (result) {
            const table = {};
            for (const descriptor of result.capabilities) {
                table[descriptor.capability_id] = descriptor;
            }
            capabilities = table;
            changed();
        });
    }

    function subscribe() {
        capability("desktop.events.subscribe", {}, function (result) {
            subscriptionId = result.subscription_id;
            seq = result.seq;
            windows = result.snapshot.windows;
            workspaces = result.snapshot.workspaces;
            outputs = result.snapshot.outputs;
            online = true;
            status = "桌面服務已連線";
            changed();
        }, function (error) {
            status = "桌面服務未連線";
            console.log("ditto-shell subscribe refused: " + error.name + " " + error.message);
        });
    }

    function applyEvent(notification) {
        if (notification.subscription_id !== subscriptionId) {
            return;
        }
        const payload = notification.payload;
        if (payload.type === "resync_required") {
            console.log("ditto-shell resync: " + payload.reason);
            subscriptionId = "";
            subscribe();
            return;
        }
        if (notification.seq !== seq + 1) {
            console.log("ditto-shell sequence gap at " + notification.seq);
            subscriptionId = "";
            subscribe();
            return;
        }
        seq = notification.seq;
        switch (payload.type) {
        case "window_upsert":
            windows = windows.filter(item => item.id !== payload.window.id).concat([payload.window]);
            break;
        case "window_removed":
            windows = windows.filter(item => item.id !== payload.window_id);
            break;
        case "workspace_upsert":
            workspaces = workspaces.filter(item => item.id !== payload.workspace.id).concat([payload.workspace]);
            break;
        case "workspace_removed":
            workspaces = workspaces.filter(item => item.id !== payload.workspace_id);
            break;
        case "output_upsert":
            outputs = outputs.filter(item => item.name !== payload.output.name).concat([payload.output]);
            break;
        case "output_removed":
            outputs = outputs.filter(item => item.name !== payload.output_name);
            break;
        }
        changed();
    }

    function receive(line) {
        if (!line) {
            return;
        }
        let message;
        try {
            message = JSON.parse(line);
        } catch (error) {
            return; // A frame Core did not send, or a truncated line: ignored.
        }
        if (message.method === "desktop.events") {
            applyEvent(message.params);
            return;
        }
        const waiting = pending[message.id];
        if (!waiting) {
            return;
        }
        delete pending[message.id];
        if (message.error) {
            if (waiting.reject) {
                waiting.reject(message.error);
            }
            return;
        }
        if (waiting.resolve) {
            waiting.resolve(message.result);
        }
    }

    /// The launcher hands the token over on an inherited descriptor; development
    /// mode is the only case where it comes from the environment.
    property Process tokenReader: Process {
        running: true
        command: Quickshell.env("DITTO_CORE_TOKEN_FD")
            ? ["sh", "-c", "head -n 1 <&" + Quickshell.env("DITTO_CORE_TOKEN_FD")]
            : ["sh", "-c", "printf %s \"$DITTO_DEV_TOKEN\""]
        stdout: StdioCollector {
            onStreamFinished: {
                client.token = text.trim();
                if (client.token.length === 0) {
                    client.status = "桌面服務未連線";
                    console.log("ditto-shell has no launcher token");
                    return;
                }
                socket.connected = true;
            }
        }
    }

    property Socket socket: Socket {
        path: client.socketPath
        parser: SplitParser {
            splitMarker: "\n"
            onRead: line => client.receive(line)
        }
        onConnectionStateChanged: {
            if (connected) {
                client.handshake();
                return;
            }
            client.online = false;
            client.handshakeDone = false;
            client.subscriptionId = "";
            client.status = client.identityRefused
                ? "桌面服務未連線，需重新啟動工作階段"
                : "桌面服務未連線";
            client.changed();
        }
    }

    /// Reconnect attempts stop once identity was refused: the one-use token is
    /// spent, and only a new session start can produce a valid one.
    property Timer retry: Timer {
        interval: 2000
        repeat: true
        running: !client.online && !client.identityRefused && client.token.length > 0
        onTriggered: socket.connected = true
    }
}
