import QtQuick
import Quickshell
import Quickshell.Io

/// The Shell's only path to the desktop (protocol 0.2). Every value here comes
/// from a snapshot plus the events that follow it; nothing is polled, and no
/// component talks to the compositor directly.
///
/// The connection runs requests both ways: the Shell's own requests have ids
/// `shell-<n>`; Core's requests (`participant.*`) have ids `core-<n>` and are
/// answered by `participant` (the ProviderHost). `shell.command` arrives as a
/// notification and goes to `commandHandler`.
///
/// Writes: every configuration change is a ChangeSet (`propose`, or
/// `setAppearance`, which Core wraps in one). There is no other write path.
QtObject {
    id: client

    // ---- configuration -----------------------------------------------------------
    property string clientKind: Quickshell.env("DITTO_CLIENT_KIND") || "quickshell"
    property string clientVersion: Quickshell.env("DITTO_CLIENT_VERSION") || "0.2.0"
    /// Topics of the main subscription. The rescue UI narrows this to what its
    /// subject may read; `tasks` has its own subscription (watchTasks).
    property var topics: ["desktop", "changes", "plugins", "notifications", "session"]
    /// Whether to load profile, packages, notifications and pending changes
    /// after connecting (the rescue UI does not).
    property bool loadDesktopState: true
    readonly property string socketPath: Quickshell.env("DITTO_CORE_SOCKET")
        || ((Quickshell.env("DITTO_RUNTIME_DIR")
            || (Quickshell.env("XDG_RUNTIME_DIR") + "/ditto")) + "/core.sock")
    readonly property string protocolVersion: "0.3.0"
    property var counter: null
    property var tr: null
    /// Answers `participant.*`: an object with handle(method, params, reply).
    property var participant: null
    /// function(commandId, args), for `shell.command`.
    property var commandHandler: null

    // ---- connection ----------------------------------------------------------------
    property bool online: false
    property bool handshakeDone: false
    property bool identityRefused: false
    property string mode: "normal"
    property string subject: ""
    property string connectionId: ""
    property string server: ""
    property string compositor: ""
    readonly property string status: {
        if (identityRefused) {
            return t(qsTr("桌面服務未連線，需重新啟動工作階段"));
        }
        if (online) {
            return mode === "rescue" ? t(qsTr("桌面服務以救援模式執行")) : t(qsTr("桌面服務已連線"));
        }
        return socket.connected ? t(qsTr("桌面服務連線中")) : t(qsTr("桌面服務未連線"));
    }

    // ---- desktop state (snapshot + events) -----------------------------------------
    property var capabilities: ({})
    property var windows: []
    property var workspaces: []
    property var outputs: []
    property var panels: []
    property var sessionState: null

    // ---- profile ---------------------------------------------------------------------
    property string profileId: ""
    property string profileName: ""
    /// The head revision of the active Profile, from `desktop.profiles.get`,
    /// `profile_changed` events and `_meta.profile_revision` of every result.
    /// Every proposal is based on it.
    property string headRevision: ""

    // ---- plugins, notifications, tasks, changes -------------------------------------
    property var packages: []
    property var notifications: []
    property bool notificationServerOwned: false
    property var policyStatus: null
    property var tasks: null
    /// idle | loading | ready | unavailable
    property string tasksStatus: "idle"
    property string tasksReason: ""
    /// Changes waiting for "keep" (preview, or a timed revert), by change id.
    property var pendingConfirmations: ({})

    signal changed()
    signal changeUpdated(var change)
    signal profileChanged(var payload)
    signal capabilitiesReloaded()
    signal panelsReported(var panels)
    signal jobUpdated(var job)
    signal hostEvent(string entryId, string name, var payload)
    signal resynced()
    signal disconnected()
    /// Core asks the Shell to show an Agent approval request.
    signal approvalRequested(var approval)

    // ---- internals -------------------------------------------------------------------
    property string token: ""
    property int nextId: 0
    property var pending: ({})
    property string subscriptionId: ""
    property int lastSeq: 0
    property bool subscribing: false
    property var buffered: []
    /// Other subscriptions on this connection: id → { lastSeq, onEvent, onLost }.
    property var extraSubscriptions: ({})
    property string tasksSubscription: ""
    property int extraSubscribing: 0
    property int tasksWatchers: 0

    function t(source) {
        return tr ? tr.t(source) : source;
    }

    function key(translationKey, args) {
        return tr ? tr.key(translationKey, args) : translationKey;
    }

    /// A list in running text; the separator is language-specific.
    function join(list) {
        return list.join(t(qsTr("、")));
    }

    function capabilityAvailable(capabilityId) {
        const descriptor = capabilities[capabilityId];
        if (!descriptor) {
            return false;
        }
        const availability = descriptor.availability || {};
        if (availability.kind === "always") {
            return true;
        }
        return availability.available !== false;
    }

    function unavailableReason(capabilityId) {
        const descriptor = capabilities[capabilityId];
        if (!descriptor) {
            return "not_bound";
        }
        const availability = descriptor.availability || {};
        return availability.available === false ? (availability.reason || "") : "";
    }

    function timeoutFor(method) {
        const descriptor = capabilities[method];
        if (descriptor && descriptor.timeout_ms && descriptor.timeout_ms.default_ms) {
            return descriptor.timeout_ms.default_ms;
        }
        if (method === "desktop.changes.propose" || method === "desktop.appearance.set"
            || method.indexOf("desktop.rescue.") === 0 || method === "desktop.changes.undo"
            || method === "desktop.changes.cancel" || method === "desktop.changes.confirm") {
            return 15000;
        }
        return 2000;
    }

    function newKey(prefix) {
        return prefix + "-" + Date.now().toString(36) + "-" + Math.floor(Math.random() * 1e12).toString(36);
    }

    function send(body) {
        socket.write(JSON.stringify(body) + "\n");
        if (socket.flush) {
            socket.flush();
        }
    }

    function call(method, params, onResult, onError, timeoutMs) {
        if (!socket.connected || (!handshakeDone && method !== "core.handshake")) {
            if (onError) {
                onError({ name: "unavailable", code: -32007, message: "not connected", data: { reason: "participant_unavailable" } });
            }
            return "";
        }
        nextId += 1;
        const id = "shell-" + nextId;
        pending[id] = {
            resolve: onResult,
            reject: onError,
            method: method,
            expires: Date.now() + (timeoutMs || 2000) + 1000
        };
        if (counter) {
            counter.record(method);
        }
        send({ jsonrpc: "2.0", id: id, method: method, params: params });
        expiry.running = true;
        return id;
    }

    /// A capability call: `_meta` with the protocol version and deadline.
    function capability(capabilityId, params, onResult, onError, options) {
        const body = params ? JSON.parse(JSON.stringify(params)) : {};
        const deadline = options && options.deadlineMs ? options.deadlineMs : timeoutFor(capabilityId);
        body._meta = { protocol_version: protocolVersion, deadline_ms: deadline };
        if (options && options.operationId) {
            body._meta.operation_id = options.operationId;
        }
        return call(capabilityId, body, onResult, onError, deadline);
    }

    // ---- window and workspace actions (G0) --------------------------------------------
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

    /// Applications start only through Core (DES-02); nothing here execs.
    function launchApp(appId, onResult, onError) {
        capability("desktop.launcher.launch", { app_id: appId }, onResult, function (error) {
            console.log("ditto-shell launch refused: " + error.name + " " + error.message);
            if (onError) {
                onError(error);
            }
        });
    }

    // ---- ChangeSets -------------------------------------------------------------------
    /// options: { mode: "apply"|"preview", surface, profileId, baseRevision }
    function propose(ops, options, onResult, onError) {
        const settings = options || {};
        const submit = function () {
            const params = {
                profile_id: settings.profileId || null,
                base_revision: settings.baseRevision || headRevision,
                mode: settings.mode || "apply",
                idempotency_key: newKey("gui"),
                surface: settings.surface || null,
                ops: ops
            };
            capability("desktop.changes.propose", params, onResult, onError);
        };
        if (!settings.baseRevision && headRevision.length === 0) {
            refreshProfile(submit, onError);
            return;
        }
        submit();
    }

    /// Appearance fields (theme, tokens, reduced_motion, reduced_transparency,
    /// low_power_style, locale); Core turns them into one ChangeSet.
    function setAppearance(fields, onResult, onError) {
        const submit = function () {
            const params = Object.assign({}, fields, { base_revision: headRevision, idempotency_key: newKey("gui") });
            capability("desktop.appearance.set", params, onResult, onError);
        };
        if (headRevision.length === 0) {
            refreshProfile(submit, onError);
            return;
        }
        submit();
    }

    function confirmChange(changeId, onResult, onError) {
        capability("desktop.changes.confirm", { change_id: changeId, idempotency_key: newKey("gui") }, onResult, onError);
    }

    function cancelChange(changeId, onResult, onError) {
        capability("desktop.changes.cancel", { change_id: changeId, idempotency_key: newKey("gui") }, onResult, onError);
    }

    function undoChange(changeId, onResult, onError) {
        capability("desktop.changes.undo", { change_id: changeId, idempotency_key: newKey("gui") }, onResult, onError);
    }

    /// Product-language description of an error. Codes and messages stay in
    /// the diagnostics area (`diagnosticText`).
    function errorText(error) {
        if (!error) {
            return "";
        }
        const data = error.data || {};
        if (error.name === "preflight_rejected" && data.reasons) {
            return data.reasons.map(reason => key(reason.detail_key, reason.detail)).join("\n");
        }
        if (data.reason && tr && tr.has(error.name + "." + data.reason)) {
            return key(error.name + "." + data.reason, data);
        }
        if (tr && tr.has("error." + error.name)) {
            return key("error." + error.name, data);
        }
        return t(qsTr("這個動作沒有完成。可以查看診斷。"));
    }

    function diagnosticText(error) {
        if (!error) {
            return "";
        }
        return error.name + " (" + error.code + "): " + error.message
            + (error.data ? "\n" + JSON.stringify(error.data) : "");
    }

    // ---- handshake and state ------------------------------------------------------------
    function handshake() {
        const params = {
            protocol_version: protocolVersion,
            client: { kind: clientKind, version: clientVersion },
            auth: { token: token }
        };
        call("core.handshake", params, function (result) {
            handshakeDone = true;
            identityRefused = false;
            mode = result.mode || "normal";
            subject = result.subject || "";
            connectionId = result.connection_id || "";
            server = result.server || "";
            compositor = result.compositor || "";
            console.log("ditto-shell connected subject=" + subject + " mode=" + mode + " connection=" + connectionId);
            loadCatalog();
            subscribe();
            if (loadDesktopState) {
                refreshProfile();
                refreshPackages();
                refreshNotifications();
                refreshPendingConfirmations();
                if (tasksWatchers > 0) {
                    subscribeTasks();
                }
            }
        }, function (error) {
            identityRefused = error.name === "identity_rejected";
            console.log("ditto-shell handshake refused: " + error.name + " " + error.message);
            socket.connected = false;
        }, 5000);
    }

    function loadCatalog() {
        capability("desktop.capabilities.list", {}, function (result) {
            const table = {};
            for (const descriptor of result.capabilities) {
                table[descriptor.capability_id] = descriptor;
            }
            capabilities = table;
            updateTasksAvailability();
            capabilitiesReloaded();
            changed();
        });
    }

    /// The tasks service comes and goes with hostd: follow the catalog's
    /// availability instead of showing the last list as if it were current.
    function updateTasksAvailability() {
        if (tasksWatchers === 0 || !capabilities["desktop.tasks.list"]) {
            return;
        }
        if (!capabilityAvailable("desktop.tasks.list")) {
            tasksStatus = "unavailable";
            tasksReason = unavailableReason("desktop.tasks.list");
        } else if (tasksStatus === "unavailable") {
            subscribeTasks();
        }
    }

    function subscribe() {
        if (subscribing) {
            return;
        }
        subscribing = true;
        subscriptionId = "";
        capability("desktop.events.subscribe", { topics: topics }, function (result) {
            subscribing = false;
            subscriptionId = result.subscription_id;
            lastSeq = result.seq;
            windows = result.snapshot.windows;
            workspaces = result.snapshot.workspaces;
            outputs = result.snapshot.outputs;
            online = true;
            changed();
            replayBuffered();
        }, function (error) {
            subscribing = false;
            console.log("ditto-shell subscribe refused: " + error.name + " " + error.message);
        });
    }

    /// Lost events, a resync request or a Core restart: start from a fresh
    /// snapshot and re-read everything that is not in the snapshot.
    function resync(reason) {
        console.log("ditto-shell resync: " + reason);
        subscribe();
        loadCatalog();
        if (loadDesktopState) {
            refreshProfile();
            refreshPanels();
            refreshNotifications();
            refreshPendingConfirmations();
            if (tasksWatchers > 0) {
                subscribeTasks();
            }
        }
        resynced();
    }

    function refreshProfile(then, onError) {
        capability("desktop.profiles.get", { history_limit: 1 }, function (result) {
            profileId = result.profile.profile_id;
            profileName = result.profile.name;
            headRevision = result.profile.head_revision;
            changed();
            if (then) {
                then();
            }
        }, function (error) {
            console.log("ditto-shell profile read refused: " + error.name + " " + error.message);
            if (onError) {
                onError(error);
            }
        });
    }

    function refreshPanels() {
        capability("desktop.panels.list", {}, function (result) {
            panels = result.panels;
            panelsReported(panels);
        });
    }

    function refreshPackages() {
        capability("desktop.plugins.list", {}, function (result) {
            packages = result.packages;
            if (tr) {
                const names = Object.assign({}, tr.packageNames);
                for (const summary of result.packages) {
                    names[summary.package_id] = summary.name;
                }
                tr.packageNames = names;
            }
            changed();
        });
    }

    function refreshNotifications() {
        if (!capabilities["desktop.notifications.list"] && Object.keys(capabilities).length > 0) {
            return;
        }
        capability("desktop.notifications.list", { limit: 50 }, function (result) {
            notifications = result.notifications;
            notificationServerOwned = result.server_owned;
        }, function (error) {
            notifications = [];
        });
        capability("desktop.notifications.policy_status", {}, function (result) {
            policyStatus = result;
        }, function (error) {
            policyStatus = null;
        });
    }

    function dismissNotification(id) {
        capability("desktop.notifications.dismiss", { id: id }, null, function (error) {
            console.log("ditto-shell dismiss refused: " + error.name + " " + error.message);
        });
    }

    function refreshPendingConfirmations() {
        capability("desktop.changes.list", { limit: 20 }, function (result) {
            const table = {};
            for (const change of result.changes) {
                if (change.confirmation && change.confirmation.state === "pending") {
                    table[change.change_id] = change;
                }
            }
            pendingConfirmations = table;
        });
    }

    function notePending(change) {
        const table = Object.assign({}, pendingConfirmations);
        if (change.confirmation && change.confirmation.state === "pending") {
            table[change.change_id] = change;
        } else {
            delete table[change.change_id];
        }
        pendingConfirmations = table;
    }

    // ---- tasks (own subscription) ---------------------------------------------------------
    function watchTasks() {
        tasksWatchers += 1;
        if (tasksWatchers === 1 && handshakeDone) {
            subscribeTasks();
        }
    }

    function unwatchTasks() {
        tasksWatchers = Math.max(0, tasksWatchers - 1);
    }

    function subscribeTasks() {
        if (tasksSubscription.length > 0) {
            refreshTasks();
            return;
        }
        tasksStatus = "loading";
        capability("desktop.tasks.subscribe", {}, function (result) {
            tasksSubscription = result.subscription_id;
            const table = Object.assign({}, extraSubscriptions);
            table[result.subscription_id] = {
                lastSeq: result.seq,
                onEvent: function (payload) {
                    if (payload.type === "host_event" && String(payload.name).indexOf("tasks/") === 0 && tasksWatchers > 0) {
                        refreshTasks();
                    }
                },
                onLost: function () {
                    tasksSubscription = "";
                    if (tasksWatchers > 0) {
                        subscribeTasks();
                    }
                }
            };
            extraSubscriptions = table;
            tasks = result.snapshot;
            tasksStatus = "ready";
            tasksReason = "";
            replayBuffered();
        }, function (error) {
            tasksStatus = "unavailable";
            tasksReason = error.data && error.data.reason ? error.data.reason : error.name;
        });
    }

    // ---- other topics (own subscriptions) ---------------------------------------------
    /// Subscribe to `topics` on a subscription of its own: `onEvent(payload)`
    /// for each event, `onLost()` when the chain breaks (resubscribe and
    /// re-read then), `onReady(result)` with the subscription's start.
    function watchTopics(topics, onEvent, onLost, onReady, onError) {
        extraSubscribing += 1;
        capability("desktop.events.subscribe", { topics: topics }, function (result) {
            extraSubscribing = Math.max(0, extraSubscribing - 1);
            const table = Object.assign({}, extraSubscriptions);
            table[result.subscription_id] = { lastSeq: result.seq, onEvent: onEvent, onLost: onLost };
            extraSubscriptions = table;
            if (onReady) {
                onReady(result);
            }
            replayBuffered();
        }, function (error) {
            extraSubscribing = Math.max(0, extraSubscribing - 1);
            if (onError) {
                onError(error);
            }
        });
    }

    function refreshTasks() {
        capability("desktop.tasks.list", {}, function (result) {
            tasks = result;
            tasksStatus = "ready";
            tasksReason = "";
        }, function (error) {
            tasksStatus = "unavailable";
            tasksReason = error.data && error.data.reason ? error.data.reason : error.name;
        });
    }

    // ---- events -------------------------------------------------------------------------
    function replayBuffered() {
        const waiting = buffered;
        buffered = [];
        for (const notification of waiting) {
            applyEvent(notification);
        }
    }

    function applyEvent(notification) {
        const id = notification.subscription_id;
        if (id === subscriptionId && id.length > 0) {
            // prev_seq is the previous seq delivered to this subscription;
            // seq itself skips the topics this subscription did not ask for.
            if (notification.prev_seq !== lastSeq) {
                console.log("ditto-shell sequence gap: expected prev_seq " + lastSeq + ", got " + notification.prev_seq);
                resync("sequence_gap");
                return;
            }
            lastSeq = notification.seq;
            if (notification.profile_revision && notification.payload.type !== "profile_changed") {
                headRevision = notification.profile_revision;
            }
            applyPayload(notification.payload);
            return;
        }
        const extra = extraSubscriptions[id];
        if (extra) {
            if (notification.payload.type === "resync_required" || notification.prev_seq !== extra.lastSeq) {
                const table = Object.assign({}, extraSubscriptions);
                delete table[id];
                extraSubscriptions = table;
                extra.onLost();
                return;
            }
            extra.lastSeq = notification.seq;
            extra.onEvent(notification.payload);
            return;
        }
        // An event may overtake the answer to the subscribe that created its
        // subscription; keep it until that answer arrives.
        if (subscribing || tasksStatus === "loading" || extraSubscribing > 0) {
            buffered = buffered.concat([notification]);
        }
    }

    function applyPayload(payload) {
        switch (payload.type) {
        case "resync_required":
            resync(payload.reason);
            return;
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
        case "profile_changed":
            if (payload.active) {
                profileId = payload.profile_id;
                headRevision = payload.head_revision;
            }
            profileChanged(payload);
            break;
        case "change_updated":
            notePending(payload.change);
            changeUpdated(payload.change);
            break;
        case "capabilities_changed":
            // Reloading the catalog also re-decides whether tasks are
            // available (updateTasksAvailability).
            loadCatalog();
            if (loadDesktopState) {
                refreshNotifications();
            }
            break;
        case "panels_changed":
            panels = payload.panels;
            panelsReported(panels);
            break;
        case "jobs_updated":
            jobUpdated(payload.job);
            if (payload.job.state === "succeeded" && loadDesktopState) {
                refreshPackages();
            }
            break;
        case "notification_posted":
            notifications = [payload.notification].concat(notifications.filter(item => item.id !== payload.notification.id));
            break;
        case "notification_closed":
            notifications = notifications.filter(item => item.id !== payload.id);
            break;
        case "host_event":
            hostEvent(payload.entry_id, payload.name, payload.payload);
            break;
        case "session_changed":
            sessionState = payload.state;
            break;
        }
        changed();
    }

    // ---- requests from Core ---------------------------------------------------------------
    function answer(id, result, error) {
        if (!socket.connected) {
            return;
        }
        if (error) {
            send({ jsonrpc: "2.0", id: id, error: { code: error.code || -32099, name: error.name || "internal", message: error.message || "" } });
        } else {
            send({ jsonrpc: "2.0", id: id, result: result === undefined ? {} : result });
        }
    }

    function handleRequest(message) {
        const id = message.id;
        if (String(message.method).indexOf("participant.") === 0 && participant) {
            participant.handle(message.method, message.params || {}, function (result, error) {
                answer(id, result, error);
            });
            return;
        }
        answer(id, null, { code: -32000, name: "unsupported", message: "this client does not answer " + message.method });
    }

    /// `shell.report`: what is mounted, after every mount change. Core answers
    /// `desktop.panels.list` from it and reads it back against targets.
    function report(observation) {
        const params = JSON.parse(JSON.stringify(observation));
        params._meta = { protocol_version: protocolVersion };
        call("shell.report", params, null, function (error) {
            console.log("ditto-shell report refused: " + error.name + " " + error.message);
        });
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
        if (message.method !== undefined) {
            if (message.method === "desktop.events") {
                applyEvent(message.params);
            } else if (message.method === "desktop.approval_requested") {
                approvalRequested(message.params || {});
            } else if (message.method === "shell.command") {
                const params = message.params || {};
                console.log("ditto-shell command " + params.command_id);
                if (commandHandler) {
                    commandHandler(params.command_id, params.args);
                }
            } else if (message.id !== undefined && message.id !== null) {
                handleRequest(message);
            }
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
        const meta = message.result && message.result._meta;
        if (meta && meta.profile_revision) {
            headRevision = meta.profile_revision;
        }
        if (waiting.resolve) {
            waiting.resolve(message.result);
        }
    }

    function failPending(reason) {
        const waiting = pending;
        pending = {};
        for (const id in waiting) {
            if (waiting[id].reject) {
                waiting[id].reject({ name: reason === "timeout" ? "timeout" : "unavailable", code: reason === "timeout" ? -32004 : -32007, message: reason, data: { reason: "participant_unavailable" } });
            }
        }
    }

    /// Requests whose answer never came: their callers learn it at the
    /// deadline. Runs only while requests are outstanding.
    property Timer expiry: Timer {
        interval: 1000
        repeat: true
        running: false
        onTriggered: {
            const now = Date.now();
            let outstanding = 0;
            for (const id in client.pending) {
                const waiting = client.pending[id];
                if (waiting.expires <= now) {
                    delete client.pending[id];
                    if (waiting.reject) {
                        waiting.reject({ name: "timeout", code: -32004, message: "no answer from Core", data: { outcome: "unknown" } });
                    }
                } else {
                    outstanding += 1;
                }
            }
            running = outstanding > 0;
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
            client.subscribing = false;
            client.buffered = [];
            client.extraSubscriptions = {};
            client.tasksSubscription = "";
            client.extraSubscribing = 0;
            client.failPending("disconnected");
            client.disconnected();
            client.changed();
        }
    }

    /// Reconnect attempts stop once identity was refused: the one-use token is
    /// spent, and only a new session start can produce a valid one.
    property Timer retry: Timer {
        interval: 2000
        repeat: true
        running: !client.online && !client.identityRefused && client.token.length > 0 && !client.socket.connected
        onTriggered: client.socket.connected = true
    }
}
