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
    /// `settings` and `provider` hold only readback confirmed on the current
    /// connection; null is the one meaning of "not confirmed" for every
    /// status, text and control. A lost connection or a failed settings read
    /// clears both, a failed provider read clears `provider`. A re-read on the
    /// same connection keeps the confirmed value until it answers.
    property var settings: null
    property var provider: null
    property var runtime: null
    property string sessionId: ""
    /// The loaded events, oldest first; at most `pageSize` × pages.
    property var events: []
    property int loadedSeq: 0
    property var turn: null
    property var login: null
    property string loginResultState: ""
    property bool loginResultReading: false
    readonly property string loginResultText: {
        if (loginResultState === "failed") return client.t(qsTr("登入未完成，請重新嘗試。"));
        if (loginResultState === "cancelled") return client.t(qsTr("已取消這次登入。"));
        if (loginResultState === "expired") return client.t(qsTr("這次登入已逾期，請重新開始。"));
        if (loginResultState === "unknown") return client.t(qsTr("目前無法確認這次登入結果；帳號狀態仍以連線讀取為準。"));
        if (loginResultState === "succeeded" && !connected) return client.t(qsTr("授權已完成，仍待確認帳號連線。"));
        return "";
    }
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
    /// The latest settings or provider status read ended in an error (other
    /// than "the Agent is still starting", which is read again). Nothing was
    /// confirmed by it: neither ready, nor off, nor offline. A new read
    /// clears it until its answer.
    property bool settingsFailed: false
    property bool providerFailed: false

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
    property bool reconnecting: false
    property bool reading: false
    property bool readAgain: false
    // Request identities belong to this projection, never to Core policy.
    property int connectionEpoch: 0
    property int settingsRequest: 0
    property int providerEpoch: 0
    property int providerRequest: 0
    property int runtimeRequest: 0
    property int loginRequest: 0
    property bool providerReading: false
    property var loginStart: null
    property string settingsContext: ""
    property var runtimeGeneration: null
    readonly property int pageSize: 50

    function invalidateProvider(keepReadback) {
        providerEpoch++;
        providerRequest++;
        runtimeRequest++;
        providerReading = false;
        providerRetry.stop();
        if (!keepReadback) provider = null;
        providerFailed = false;
    }

    function forgetLogin() {
        loginRequest++;
        // Runtime reads may discard stale callbacks. Release the start and
        // its unbound id here, without waiting for one of those callbacks.
        if (loginStart) loginStart();
        login = null;
        loginResultReading = false;
        loginResultState = "";
        loginWatch.stop();
    }

    onSettingsChanged: {
        const context = settings ? String(settings.enabled) + ":" + settings.provider : "";
        if (context !== settingsContext) {
            settingsContext = context;
            if (login || loginStart) cancelLogin();
            else forgetLogin();
            invalidateProvider();
        }
    }

    onRuntimeChanged: {
        if (!runtime || runtime.generation === undefined) return;
        const changed = runtimeGeneration !== null && runtimeGeneration !== runtime.generation;
        runtimeGeneration = runtime.generation;
        if (changed) {
            // Bound attempts belong to the generation that served their start.
            // A preflight has not issued login yet; its fresh generation
            // must not invalidate the new start it is about to serve.
            if (login || !loginStart || loginStart.generation !== undefined) forgetLogin();
            invalidateProvider();
            if (!loginStart && client.online && wanted && enabled && settings.provider === "codex-app-server")
                providerRetry.restart();
        }
    }

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

    /// What Core's readback says about AI being usable now:
    /// pending (not read yet, or a read is still out) | failed (a read failed;
    /// nothing confirmed) | disabled | model_offline (unavailable or signed
    /// out) | core_offline | ready. Display only; controls stay fail-closed.
    readonly property string aiStatus: client.online === false ? "core_offline"
        : !settings ? (settingsFailed ? "failed" : "pending")
        : settings.enabled !== true ? "disabled"
        : connected ? "ready"
        : provider ? "model_offline"
        : providerFailed ? "failed" : "pending"

    /// A failed read in product language; empty unless aiStatus is "failed".
    readonly property string readFailureText: aiStatus !== "failed" ? ""
        : !settings ? client.t(qsTr("無法讀取 AI 設定；重新開啟會再讀取"))
            : client.t(qsTr("無法確認模型連線；重新開啟會再讀取"))

    readonly property string transportText: reconnecting
        ? client.t(qsTr("正在重新連線；將查詢實際結果")) : ""

    /// Unknown settings/provider are not readback that AI is disabled/offline.
    /// `enabled` remains fail-closed for controls while these reads are pending.
    readonly property string offlineReason: client.online === false
        ? client.t(qsTr("桌面服務未連線"))
        : settings && settings.enabled === false
            ? client.t(qsTr("AI 對話已關閉；桌面仍可照常操作"))
            : settings && settings.enabled === true && provider && !connected
                ? client.t(qsTr("模型尚未連接；桌面仍可照常操作")) : ""

    readonly property string stateText: {
        const result = turn && ["partial", "unknown", "cancelled"].indexOf(turn.state) >= 0
            ? failureText(turn) : "";
        if (taskState === "offline") {
            // Keep both the known terminal outcome and the current readback.
            const reason = offlineReason || readFailureText;
            if (result) return result + (reason ? " · " + reason : "");
            return reason || client.t(qsTr("待命中"));
        }
        if (result) return result;
        if (turn && turn.state === "cancelling") return client.t(qsTr("正在停止"));
        switch (taskState) {
        case "starting":
            return client.t(qsTr("正在啟動對話"));
        case "thinking":
            return client.t(qsTr("正在理解需求；可停止"));
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

    /// The status part of the `chat` control line. Unconfirmed (not read, or
    /// the read failed) is not reported as idle or as a confirmed value:
    /// state/enabled/connected are null and ai_status says which.
    function chatStatus() {
        return {
            state: taskState === "offline" && !offlineReason ? null : taskState,
            ai_status: aiStatus,
            text: stateText,
            enabled: settings ? enabled : null,
            connected: provider ? connected : null
        };
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
            state.reconnecting = false;
            if (state.turn) state.refreshTurnFrom({ data: { turn_id: state.turn.turn_id } });
            state.readNew();
        }, function (error) {
            state.setError(error);
        });
    }

    function refreshSettings() {
        settingsFailed = false;
        const connection = connectionEpoch, request = ++settingsRequest;
        const current = () => connection === connectionEpoch && request === settingsRequest && client.online;
        client.capability("agent.settings.describe", {}, function (result) {
            if (!current()) return;
            settings = result;
            settingsFailed = false;
            if (settings.enabled) {
                refreshProvider();
                loadSession();
            }
        }, function (error) {
            if (!current()) return;
            // Unconfirmed settings: the provider status under them is not
            // shown as confirmed either (it is read again after settings).
            settings = null;
            provider = null;
            settingsFailed = true;
            setError(error);
        });
    }

    function refreshRuntime(then, failed) {
        const connection = connectionEpoch, request = ++runtimeRequest;
        client.capability("agent.runtime.get", {}, function (result) {
            if (connection !== connectionEpoch || request !== runtimeRequest || !client.online) return;
            runtime = result;
            if (then) then(result);
        }, function (error) {
            if (connection !== connectionEpoch || request !== runtimeRequest || !client.online) return;
            if (failed) failed(error);
        });
    }

    function refreshProvider(then, confirmation) {
        if (loginStart || !client.online || !enabled || settings.provider === "direct-model") return;
        const epoch = providerEpoch, request = ++providerRequest;
        const current = () => epoch === providerEpoch && request === providerRequest && client.online;
        providerFailed = false;
        providerReading = true;
        const expireUnconfirmed = function () {
            const attempt = confirmation || login;
            if (!attempt || Date.now() < attempt.expires_at_ms) return;
            if (login) expireLogin();
            else loginResultState = "expired";
        };
        const failed = function (error) {
            if (!current()) return;
            providerReading = false;
            provider = null;
            expireUnconfirmed();
            if (!current()) return;
            // Retain the existing startup retry. A read failure is unknown,
            // not proof of sign-out or of a failed device-code exchange.
            providerFailed = !(error.name === "unavailable" && wanted);
            if (!providerFailed) providerRetry.restart();
            else setError(error);
        };
        // Core already exposes generation. Bracket the account read with its
        // snapshots so a restarted backend cannot confirm an old response.
        refreshRuntime(function (before) {
            if (!current()) return;
            if (login && Date.now() >= login.expires_at_ms) expireLogin();
            client.capability("agent.providers.status", { provider: "codex-app-server" }, function (result) {
                if (!current()) return;
                refreshRuntime(function (after) {
                    if (!current()) return;
                    providerReading = false;
                    if (before.generation !== after.generation) return;
                    // Attempt expiry cannot veto a fenced official account
                    // readback. Only an unconfirmed account keeps its deadline.
                    provider = result;
                    providerFailed = false;
                    if (result.authenticated) forgetLogin();
                    else expireUnconfirmed();
                    if (then) then(result);
                }, failed);
            }, failed, { deadlineMs: 30000 });
        }, failed);
    }

    property Timer providerRetry: Timer {
        interval: 1500
        onTriggered: if (state.wanted && state.enabled && !state.connected && !state.providerReading && !state.loginStart) state.refreshProvider()
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
        const connection = connectionEpoch, request = ++settingsRequest;
        const current = () => connection === connectionEpoch && request === settingsRequest && client.online;
        client.capability("agent.settings.patch", { expected_revision: settings.revision, settings: next }, function (result) {
            if (!current()) return;
            settings = result;
            setError(null);
            if (on) {
                refreshProvider();
                loadSession();
            }
        }, function (error) {
            if (!current()) return;
            setError(error);
            refreshSettings(); // another surface changed it: show the current one
        });
    }

    // ---- sign-in ------------------------------------------------------------------------
    /// The official device-code sign-in, run by the Agent's backend. The
    /// browser gets the verification page and the person types the one-time
    /// code shown here; no token ever reaches the Shell.
    function startLogin() {
        if (!client.online || !enabled || settings.provider !== "codex-app-server" || login || loginStart) return;
        // Keep the last account read visible while the code is displayed.
        // Starting authorization does not itself change that readback.
        invalidateProvider(true);
        const request = ++loginRequest, connection = connectionEpoch;
        let unbound = null;
        // The identity is also its owner's finalizer; forgetLogin can release
        // it synchronously even when a pending runtime callback is discarded.
        const token = function () { release(); cleanup(); };
        loginStart = token;
        loginResultState = "";
        const current = () => request === loginRequest && connection === connectionEpoch && client.online
            && enabled && settings.provider === "codex-app-server";
        const release = () => { if (loginStart === token) loginStart = null; };
        const cleanup = function () {
            const result = unbound;
            unbound = null; // drain once, including invalidation during verification
            if (!result) return;
            // The serving generation may have moved. Cancel only this returned
            // id on this connection; the backend rejects an unrelated id.
            if (connection === connectionEpoch && client.online && (!login || login.login_id !== result.login_id))
                client.capability("agent.providers.cancel_login", { provider: "codex-app-server", login_id: result.login_id });
        };
        const failed = function (error) {
            token();
            if (current()) setError(error);
        };
        refreshRuntime(function (before) {
            if (!current()) { release(); return; }
            token.generation = before.generation;
            client.capability("agent.providers.login", { provider: "codex-app-server" }, function (result) {
                unbound = result;
                if (!current()) { token(); return; }
                refreshRuntime(function (after) {
                    release();
                    if (!current() || before.generation !== after.generation || Date.now() >= result.expires_at_ms) {
                        if (current() && Date.now() >= result.expires_at_ms) loginResultState = "expired";
                        cleanup();
                        return;
                    }
                    unbound = null; // ownership moves to the bound attempt
                    login = result;
                    loginResultState = "pending";
                    setError(null);
                    Qt.openUrlExternally(result.auth_url);
                    loginWatch.start();
                }, failed);
            }, failed, { deadlineMs: 30000 });
        }, failed);
    }

    function cancelLogin(expired) {
        const attempt = login;
        forgetLogin();
        // Expiry fences only attempt replies, never a current account read.
        if (expired !== true) invalidateProvider();
        if (expired === true) loginResultState = "expired";
        if (!attempt || !client.online) return;
        const epoch = providerEpoch, request = loginRequest;
        const readback = function () {
            if (epoch === providerEpoch && client.online && enabled && settings.provider === "codex-app-server" && !providerReading)
                refreshProvider();
        };
        client.capability("agent.providers.cancel_login", { provider: "codex-app-server", login_id: attempt.login_id }, function (result) {
            if (epoch !== providerEpoch || request !== loginRequest) return;
            if (expired === true || Date.now() >= attempt.expires_at_ms) loginResultState = "expired";
            else loginResultState = result.completed === true ? "cancelled" : "unknown";
            readback();
        }, function () {
            if (epoch !== providerEpoch || request !== loginRequest) return;
            loginResultState = expired === true || Date.now() >= attempt.expires_at_ms ? "expired" : "unknown";
            readback(); // no raw provider error; cancellation is not sign-out
        });
    }

    function expireLogin() {
        cancelLogin(true);
    }

    function refreshLoginResult() {
        if (!login || loginResultReading || !client.online || !enabled || settings.provider !== "codex-app-server") return;
        const attempt = login, request = loginRequest, connection = connectionEpoch, generation = runtimeGeneration;
        if (Date.now() >= attempt.expires_at_ms) { expireLogin(); return; }
        // Older Core catalogs are supported without sending an unknown method.
        if (typeof client.capabilityAvailable !== "function" || !client.capabilityAvailable("agent.providers.login_result")) {
            loginResultState = "unknown";
            return;
        }
        const current = () => login === attempt && request === loginRequest && connection === connectionEpoch
            && generation === runtimeGeneration && client.online && enabled && settings.provider === "codex-app-server";
        loginResultReading = true;
        const unknown = function () {
            if (!current()) return;
            loginResultReading = false;
            if (Date.now() >= attempt.expires_at_ms) { expireLogin(); return; }
            loginResultState = "unknown";
        };
        client.capability("agent.providers.login_result", { provider: "codex-app-server", login_id: attempt.login_id, generation: generation }, function (result) {
            if (!current()) return;
            loginResultReading = false;
            if (Date.now() >= attempt.expires_at_ms) { expireLogin(); return; }
            const states = ["pending", "succeeded", "failed", "cancelled", "expired", "unknown"];
            if (!result || Object.keys(result).some(key => ["login_id", "generation", "state", "_meta"].indexOf(key) < 0)
                || result.login_id !== attempt.login_id || result.generation !== generation || states.indexOf(result.state) < 0) {
                unknown();
                return;
            }
            const outcome = result.state;
            if (outcome === "pending" || outcome === "unknown") { loginResultState = outcome; return; }
            forgetLogin();
            invalidateProvider(true); // fence older reads, keep independently confirmed account
            loginResultState = outcome;
            if (outcome === "succeeded") {
                // Retain only identity/deadline in this bounded confirmation
                // callback. The code surface is already cleared by forgetLogin.
                delete attempt.auth_url;
                delete attempt.user_code;
                refreshProvider(undefined, attempt);
            }
        }, unknown, { deadlineMs: 30000 });
    }

    /// Only bounded attempt polling; each kind has at most one outstanding read.
    property Timer loginWatch: Timer {
        interval: 3000
        repeat: true
        onTriggered: {
            if (state.login && Date.now() >= state.login.expires_at_ms) {
                state.expireLogin();
                return;
            }
            if (!state.login || !state.wanted || !state.client.online || !state.enabled || state.settings.provider !== "codex-app-server") {
                stop();
                return;
            }
            state.refreshLoginResult();
            if (state.login && !state.providerReading) state.refreshProvider();
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
        const connection = connectionEpoch, request = ++settingsRequest;
        const current = () => connection === connectionEpoch && request === settingsRequest && client.online;
        client.capability("agent.settings.patch", { expected_revision: settings.revision, settings: next }, function (result) {
            if (!current()) return;
            settings = result;
            setError(null);
            if (then) {
                then(result);
            }
        }, function (error) {
            if (!current()) return;
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
        forgetLogin();
        invalidateProvider();
        const epoch = providerEpoch;
        client.capability("agent.providers.logout", { provider: "codex-app-server" }, function () {
            if (epoch === providerEpoch) refreshProvider();
        }, function (error) {
            if (epoch === providerEpoch) setError(error);
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
            state.connectionEpoch++;
            state.settingsRequest++;
            state.forgetLogin();
            state.invalidateProvider();
            state.runtime = null;
            state.runtimeGeneration = null;
            state.reconnecting = state.wanted;
            state.subscriptionId = "";
            // Readback from the lost connection is not confirmed any more.
            state.settings = null;
            state.provider = null;
        }
        function onOnlineChanged() {
            if (state.client.online && state.wanted && state.subscriptionId.length === 0) {
                state.follow();
                state.refreshSettings();
            }
        }
    }
}
