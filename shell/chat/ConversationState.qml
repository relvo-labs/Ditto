import QtQuick

/// The one conversation model the chat surfaces read (plan/04/05 §1). Core
/// owns the conversation: accepted messages, tool records, answers and turn
/// states all come from `agent.*` reads and `conversation_updated` events.
/// What lives here is a projection (the loaded page of events) and what the
/// user has not sent yet (the draft). Nothing is written to disk.
///
/// The character's task state is derived from Core's turn state and the
/// tool records, never from "a request is out": a failed or lost request
/// ends the state instead of leaving it thinking (AVA-04).
QtObject {
    id: state

    required property var client

    // ---- what Core says -------------------------------------------------------------
    property var settings: null
    property var provider: null
    property var runtime: null
    property string sessionId: ""
    /// The loaded events, oldest first; at most `pageSize` × pages.
    property var events: []
    property int loadedSeq: 0
    property var turn: null
    property var login: null
    /// The answer as it streams for the active turn (display only; the
    /// stored answer replaces it).
    property string streamText: ""
    property string streamTurn: ""
    /// Conversations, newest first, for the history list.
    property var sessions: []
    /// The lowest seq loaded: older pages are read on request.
    property int firstSeq: 0
    readonly property bool hasOlder: firstSeq > 0
    /// The last error, in product language; diagnostics separately.
    property string errorText: ""
    property string errorDiagnostic: ""

    // ---- what the user has not sent -------------------------------------------------
    property string draft: ""
    property bool sending: false
    /// Context the person attached to the draft: Core references (label,
    /// size, hash), with a preview fetched on demand. The content stays in
    /// Core; removing a chip releases it there.
    property var attached: []
    property var previews: ({})
    property bool attaching: false

    // ---- internals --------------------------------------------------------------------
    property bool wanted: false
    property string subscriptionId: ""
    property bool reading: false
    property bool readAgain: false
    readonly property int pageSize: 50

    readonly property bool enabled: !!settings && settings.enabled === true
    readonly property bool connected: !!provider && provider.available === true && provider.authenticated === true
    readonly property bool turnActive: !!turn && ["queued", "running", "awaiting_approval", "cancelling"].indexOf(turn.state) >= 0

    /// idle | thinking | executing | awaiting | done | failed | offline
    /// (PRD AVA-04's seven states), plus "starting" for Core's lifecycle.
    readonly property string taskState: {
        if (!client.online || !enabled) {
            return "offline";
        }
        if (turn && turnActive) {
            if (turn.state === "awaiting_approval") {
                return "awaiting";
            }
            return toolOpen ? "executing" : "thinking";
        }
        if (runtime && runtime.phase === "starting") {
            return "starting";
        }
        if (!connected) {
            return "offline";
        }
        if (turn && turn.state === "succeeded") {
            return "done";
        }
        if (turn && ["failed", "partial", "unknown", "cancelled"].indexOf(turn.state) >= 0) {
            return "failed";
        }
        return "idle";
    }

    /// A tool call of the active turn without its result yet.
    readonly property bool toolOpen: {
        if (!turn) {
            return false;
        }
        const open = {};
        for (const event of events) {
            if (!event.data || event.data.turn_id !== turn.turn_id) {
                continue;
            }
            if (event.type === "tool/call") {
                open[event.data.operation_id] = true;
            } else if (event.type === "tool/result") {
                delete open[event.data.operation_id];
            }
        }
        return Object.keys(open).length > 0;
    }

    readonly property string stateText: {
        switch (taskState) {
        case "offline":
            return !client.online ? client.t(qsTr("桌面服務未連線"))
                : !enabled ? client.t(qsTr("AI 對話已關閉；桌面仍可照常操作"))
                : client.t(qsTr("模型尚未連接；桌面仍可照常操作"));
        case "starting":
            return client.t(qsTr("正在啟動對話"));
        case "thinking":
            return turn && turn.state === "cancelling" ? client.t(qsTr("正在停止"))
                : client.t(qsTr("正在理解需求；可停止"));
        case "executing":
            return client.t(qsTr("正在套用並確認桌面變更"));
        case "awaiting":
            return client.t(qsTr("需要你的確認"));
        case "done":
            return client.t(qsTr("完成；可以在變更紀錄撤銷"));
        case "failed":
            return failureText(turn);
        }
        return client.t(qsTr("可以描述想調整的桌面"));
    }

    function failureText(t) {
        if (!t) {
            return "";
        }
        switch (t.state) {
        case "partial":
            return client.t(qsTr("只完成了一部分；請查看變更卡"));
        case "unknown":
            return client.t(qsTr("結果尚未確認；不要重複送出，請查看變更紀錄"));
        case "cancelled":
            return client.t(qsTr("已停止"));
        }
        switch (t.error_reason) {
        case "rate_limited":
            return client.t(qsTr("訂閱額度已用完；等額度重設後再試"));
        case "provider_unavailable":
        case "provider_timeout":
            return client.t(qsTr("模型沒有回應；桌面沒有被改動，可以再試一次"));
        case "backend_unsupported":
            return client.t(qsTr("模型後端無法使用"));
        case "tool_error":
            return client.t(qsTr("桌面變更沒有完成；請查看變更卡"));
        }
        return client.t(qsTr("沒有完成；可以再試一次"));
    }

    function setError(error) {
        errorText = error ? client.errorText(error) : "";
        errorDiagnostic = error ? client.diagnosticText(error) : "";
    }

    // ---- opening ------------------------------------------------------------------------
    /// The chat surface opened: read settings, the provider and the latest
    /// conversation, and follow it. The Agent starts on demand (the provider
    /// read asks Core to start it); nothing runs while the chat is unused.
    function open() {
        wanted = true;
        refreshSettings();
        refreshSessions();
        if (subscriptionId.length === 0) {
            follow();
        }
    }

    function follow() {
        if (!client.online) {
            return;
        }
        client.watchTopics(["conversations"], function (payload) {
            state.applyEvent(payload);
        }, function () {
            state.subscriptionId = "";
            state.follow();
            state.readNew();
        }, function (result) {
            state.subscriptionId = result.subscription_id;
            state.readNew();
        }, function (error) {
            state.setError(error);
        });
    }

    function refreshSettings() {
        client.capability("agent.settings.describe", {}, function (result) {
            settings = result;
            if (settings.enabled) {
                refreshProvider();
                loadSession();
            }
        }, function (error) {
            setError(error);
        });
    }

    function refreshRuntime() {
        client.capability("agent.runtime.get", {}, function (result) {
            runtime = result;
        });
    }

    function refreshProvider(then) {
        refreshRuntime();
        client.capability("agent.providers.status", { provider: "codex-app-server" }, function (result) {
            provider = result;
            if (result.authenticated) {
                login = null;
            }
            refreshRuntime();
            if (then) {
                then(result);
            }
        }, function (error) {
            provider = null;
            refreshRuntime();
            // The Agent may still be starting; ask once more shortly.
            if (error.name === "unavailable" && wanted) {
                providerRetry.restart();
            } else {
                setError(error);
            }
        }, { deadlineMs: 30000 });
    }

    property Timer providerRetry: Timer {
        interval: 1500
        onTriggered: if (state.wanted && state.enabled && !state.connected) state.refreshProvider()
    }

    function setEnabled(on) {
        if (!settings) {
            return;
        }
        const next = {};
        for (const name in settings) {
            if (name !== "_meta") {
                next[name] = settings[name];
            }
        }
        next.enabled = on;
        client.capability("agent.settings.patch", { expected_revision: settings.revision, settings: next }, function (result) {
            settings = result;
            setError(null);
            if (on) {
                refreshProvider();
                loadSession();
            }
        }, function (error) {
            setError(error);
            refreshSettings(); // another surface changed it: show the current one
        });
    }

    // ---- sign-in ------------------------------------------------------------------------
    /// The official browser sign-in, run by the Agent's backend. The browser
    /// gets the authorization address; no token ever reaches the Shell.
    function startLogin() {
        client.capability("agent.providers.login", { provider: "codex-app-server" }, function (result) {
            login = result;
            setError(null);
            Qt.openUrlExternally(result.auth_url);
            loginWatch.start();
        }, function (error) {
            setError(error);
        }, { deadlineMs: 30000 });
    }

    function cancelLogin() {
        if (!login) {
            return;
        }
        const id = login.login_id;
        login = null;
        loginWatch.stop();
        client.capability("agent.providers.cancel_login", { provider: "codex-app-server", login_id: id }, null, function (error) {
            setError(error);
        });
    }

    /// Sign-in finishes in the browser; there is no event for it, so the
    /// status is read every few seconds while (and only while) a sign-in is
    /// pending, until its expiry.
    property Timer loginWatch: Timer {
        interval: 3000
        repeat: true
        onTriggered: {
            if (!state.login || Date.now() > state.login.expires_at_ms || !state.wanted) {
                state.login = null;
                stop();
                return;
            }
            state.refreshProvider(function (result) {
                if (result.authenticated) {
                    state.loginWatch.stop();
                }
            });
        }
    }

    // ---- the conversation -------------------------------------------------------------
    function loadSession() {
        if (sessionId.length > 0) {
            readNew();
            return;
        }
        client.capability("agent.sessions.list", {}, function (result) {
            const sessions = result.sessions || [];
            if (sessions.length === 0) {
                return;
            }
            const latest = sessions.slice().sort((a, b) => a.created_at < b.created_at ? 1 : -1)[0];
            selectSession(latest.session_id, latest.next_seq);
        }, function (error) {
            setError(error);
        });
    }

    function refreshSessions() {
        client.capability("agent.sessions.list", {}, function (result) {
            sessions = (result.sessions || []).slice().sort((a, b) => a.created_at < b.created_at ? 1 : -1);
        });
    }

    /// Show another conversation: its last page, then live updates.
    function selectSession(id, nextSeq) {
        sessionId = id;
        events = [];
        turn = null;
        streamText = "";
        loadedSeq = Math.max(0, (nextSeq || 0) - pageSize);
        firstSeq = loadedSeq;
        readNew();
    }

    /// One more page before what is loaded (long conversations are never
    /// loaded whole).
    function loadOlder() {
        if (!hasOlder || sessionId.length === 0) {
            return;
        }
        const from = Math.max(0, firstSeq - pageSize);
        const count = firstSeq - from;
        client.capability("agent.sessions.read", { session_id: sessionId, offset: from, limit: count }, function (result) {
            const older = (result.events || []).filter(event => event.seq < firstSeq);
            events = older.concat(events);
            firstSeq = from;
        }, function (error) {
            setError(error);
        });
    }

    function deleteSession(id) {
        client.capability("agent.sessions.delete", { session_id: id }, function () {
            if (id === sessionId) {
                newConversation();
            }
            refreshSessions();
        }, function (error) {
            setError(error);
        });
    }

    function undoChange(changeId) {
        client.undoChange(changeId, function () {
            setError(null);
        }, function (error) {
            setError(error);
        });
    }

    /// Settings changes go through Core's revision check; a conflict re-reads.
    function patchSettings(fields, then) {
        if (!settings) {
            return;
        }
        const next = {};
        for (const name in settings) {
            if (name !== "_meta") {
                next[name] = settings[name];
            }
        }
        Object.assign(next, fields);
        client.capability("agent.settings.patch", { expected_revision: settings.revision, settings: next }, function (result) {
            settings = result;
            setError(null);
            if (then) {
                then(result);
            }
        }, function (error) {
            setError(error);
            refreshSettings();
        });
    }

    function chooseModel(model, effort) {
        patchSettings({ model: model, reasoning_effort: effort || null });
    }

    function setApprovalMode(mode) {
        patchSettings({ approval_mode: mode });
    }

    function logout() {
        client.capability("agent.providers.logout", { provider: "codex-app-server" }, function () {
            refreshProvider();
        }, function (error) {
            setError(error);
        }, { deadlineMs: 30000 });
    }

    /// The key goes from the form to Core to the keyring; only its
    /// reference comes back. The caller clears the field afterwards.
    function saveApiKey(endpoint, model, key, onDone) {
        client.capability("agent.credentials.create", { provider: "direct-model", secret: key, idempotency_key: client.newKey("key") }, function (status) {
            patchSettings({ provider: "direct-model", endpoint: endpoint, model: model || null,
                auth: { kind: "api_key", credential_ref: status.credential_ref } }, onDone);
        }, function (error) {
            setError(error);
        });
    }

    function useSubscription() {
        patchSettings({ provider: "codex-app-server", endpoint: null, auth: null, model: null });
    }

    function newConversation() {
        sessionId = "";
        events = [];
        loadedSeq = 0;
        firstSeq = 0;
        turn = null;
        streamText = "";
    }

    /// Read the events after what is loaded. One read at a time; an update
    /// that arrives meanwhile asks for one more read after it.
    function readNew() {
        if (sessionId.length === 0) {
            return;
        }
        if (reading) {
            readAgain = true;
            return;
        }
        reading = true;
        client.capability("agent.sessions.read", { session_id: sessionId, offset: loadedSeq, limit: pageSize }, function (result) {
            reading = false;
            const fresh = (result.events || []).filter(event => event.seq >= loadedSeq);
            if (fresh.length > 0) {
                events = events.concat(fresh).slice(-pageSize * 4);
                loadedSeq = fresh[fresh.length - 1].seq + 1;
                for (const event of fresh) {
                    if (event.type === "user/message" || event.type === "turn/end") {
                        refreshTurnFrom(event);
                    }
                    if (event.type === "assistant/message" && event.data && event.data.turn_id === streamTurn) {
                        streamText = "";
                    }
                }
            }
            if (readAgain || fresh.length === pageSize) {
                readAgain = false;
                readNew();
            }
        }, function (error) {
            reading = false;
            setError(error);
        });
    }

    function refreshTurnFrom(event) {
        const id = event.data && event.data.turn_id;
        if (!id) {
            return;
        }
        client.capability("agent.turns.get", { turn_id: id }, function (result) {
            if (!turn || turn.turn_id === result.turn_id || result.created_at >= turn.created_at) {
                turn = result;
            }
        });
    }

    function applyEvent(payload) {
        if (payload.type === "conversation_delta") {
            if (payload.session_id === sessionId) {
                if (streamTurn !== payload.turn_id) {
                    streamTurn = payload.turn_id;
                    streamText = "";
                }
                streamText += payload.text;
            }
            return;
        }
        if (payload.type !== "conversation_updated") {
            return;
        }
        if (payload.deleted && payload.session_id === sessionId) {
            newConversation();
            return;
        }
        if (payload.session_id !== sessionId) {
            return;
        }
        if (payload.turn_id && payload.turn_state) {
            if (turn && turn.turn_id === payload.turn_id) {
                turn = Object.assign({}, turn, { state: payload.turn_state });
            } else {
                refreshTurnFrom({ data: { turn_id: payload.turn_id } });
            }
            if (["succeeded", "failed", "partial", "unknown", "cancelled"].indexOf(payload.turn_state) >= 0) {
                refreshTurnFrom({ data: { turn_id: payload.turn_id } });
            }
        }
        if (payload.next_seq > loadedSeq) {
            readNew();
        }
    }

    /// Send the draft. It stays in the field until Core has accepted it, so
    /// a failure keeps the text; a retry reuses the same message key, so Core
    /// cannot accept it twice.
    property string pendingKey: ""
    function send() {
        const text = draft.trim();
        if (text.length === 0 || sending || turnActive) {
            return;
        }
        if (pendingKey.length === 0) {
            pendingKey = client.newKey("chat");
        }
        sending = true;
        const submit = function () {
            const contexts = attached.map(item => item.context_id);
            client.capability("agent.turns.submit", { session_id: sessionId, client_message_id: pendingKey, text: text, contexts: contexts }, function (result) {
                sending = false;
                pendingKey = "";
                draft = "";
                attached = [];
                previews = {};
                turn = result;
                setError(null);
                readNew();
            }, function (error) {
                sending = false;
                setError(error);
            });
        };
        if (sessionId.length > 0) {
            submit();
            return;
        }
        client.capability("agent.sessions.create", { title: text.slice(0, 40), idempotency_key: pendingKey + "-session" }, function (result) {
            sessionId = result.session_id;
            loadedSeq = 0;
            events = [];
            submit();
        }, function (error) {
            sending = false;
            setError(error);
        });
    }

    /// kind: "file" (with an absolute path), "clipboard" or "capture".
    /// Taking context is always this explicit act; nothing watches the
    /// clipboard or the screen.
    function attach(kind, path) {
        if (attaching) {
            return;
        }
        attaching = true;
        const params = { kind: kind };
        if (path) {
            params.path = path;
        }
        client.capability("desktop.context.acquire", params, function (reference) {
            attaching = false;
            attached = attached.concat([reference]);
            setError(null);
            client.capability("desktop.context.preview", { context_id: reference.context_id }, function (preview) {
                const table = Object.assign({}, previews);
                table[reference.context_id] = preview;
                previews = table;
            });
        }, function (error) {
            attaching = false;
            setError(error);
        }, { deadlineMs: 15000 });
    }

    function detach(contextId) {
        attached = attached.filter(item => item.context_id !== contextId);
        const table = Object.assign({}, previews);
        delete table[contextId];
        previews = table;
        client.capability("desktop.context.release", { context_id: contextId });
    }

    function stop() {
        if (!turn || !turnActive) {
            return;
        }
        client.capability("agent.turns.cancel", { turn_id: turn.turn_id }, function (result) {
            turn = result;
        }, function (error) {
            setError(error);
        });
    }

    /// The change records a turn produced, for its cards.
    function changeIds() {
        const ids = [];
        for (const event of events) {
            if (event.type === "tool/result" && event.data && event.data.change_id && ids.indexOf(event.data.change_id) < 0) {
                ids.push(event.data.change_id);
            }
        }
        return ids;
    }

    property Connections connection: Connections {
        target: state.client
        function onDisconnected() {
            state.subscriptionId = "";
        }
        function onOnlineChanged() {
            if (state.client.online && state.wanted && state.subscriptionId.length === 0) {
                state.follow();
                state.refreshSettings();
            }
        }
    }
}
