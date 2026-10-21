import QtQuick
import QtTest
import "../../../../shell/chat" as Chat
import "../../../../shell/centers" as Centers
import "../../../../shell/assistant" as Assistant
import "../../../../shell/jelly" as Jelly

// Behavioral state-table tests. All RPC replies are controlled; no backend,
// credentials, login, process or remote provider is used.
TestCase {
    id: suite
    name: "RuntimeEvidence"
    width: 900
    height: 900
    visible: true
    when: windowShown
    QtObject {
        id: client
        property bool online: true
        property var pending: []
        property var replies: ({})
        signal disconnected()
        signal changeUpdated(var change)
        function t(text) { return text; }
        function key(text) { return text; }
        function newKey(prefix) { return prefix + "-fixture"; }
        function capabilityAvailable(name) { return false; }
        function errorText(error) { return "fixture error"; }
        function diagnosticText(error) { return "fixture diagnostic"; }
        function watchTopics(topics, event, resync, ready, fail) { ready({subscription_id: "fixture"}); }
        function capability(method, params, ok, fail, options) {
            if (replies[method] !== undefined) {
                if (ok) ok(replies[method]);
            } else {
                pending = pending.concat([{method: method, params: params, ok: ok, fail: fail}]);
            }
        }
    }
    Jelly.Tokens { id: tokens }
    Component { id: stateComponent; Chat.ConversationState {} }
    Component { id: settingsComponent; Centers.AISettings {} }
    Component { id: chatComponent; Chat.ChatBody {} }
    Component { id: entryComponent; Assistant.AssistantEntry {} }
    readonly property var prefs: ({enabled: true, revision: "fixture", provider: "codex-app-server", model: null, approval_mode: "ask"})
    readonly property var account: ({available: true, authenticated: true, provider: "codex-app-server", models: [], rate_limits: null})
    readonly property var unsupported: ({state: "failed", turn_id: "turn", created_at: "2026-10-20", error_reason: "backend_unsupported"})
    property var state: null
    function snapshot(generation, reason, pid) {
        return {phase: "ready", generation: generation, backend_pid: pid === undefined ? 42 : pid,
            isolation_verified: true, failure_reason: reason};
    }
    function init() {
        client.online = true;
        tokens.appearance = {theme: "soft-jelly-light", tokens: {ui_style: "j1"}};
        client.pending = [];
        client.replies = {"agent.sessions.list": {sessions: []}, "agent.sessions.read": {events: []}};
        state = createTemporaryObject(stateComponent, suite, {client: client});
        verify(state !== null);
        state.settings = prefs;
        state.provider = account;
        state.runtime = snapshot(4, null);
        state.sessionId = "session";
    }
    function last(method) {
        const calls = client.pending.filter(call => call.method === method);
        verify(calls.length > 0, "missing " + method);
        return calls[calls.length - 1];
    }
    function noModel() {
        verify(state.failureText(unsupported).indexOf("目前選的模型") < 0, state.failureText(unsupported));
    }
    function unavailable() {
        compare(state.connected, false);
        verify(state.aiStatus !== "ready");
        compare(state.canLogin, false);
        compare(state.chatStatus().connected, false);
        noModel();
    }
    function readRuntime(value) {
        state.refreshRuntime();
        last("agent.runtime.get").ok(value);
    }
    function find(item, predicate) {
        if (predicate(item)) return item;
        for (const child of (item.children || []).concat(item.contentItem ? [item.contentItem] : [])) {
            const found = find(child, predicate);
            if (found) return found;
        }
        return null;
    }
    function test_healthy_data() { return [{tag: "null", reason: null}, {tag: "empty", reason: ""}]; }
    function test_healthy(data) {
        readRuntime(snapshot(4, data.reason));
        compare(state.aiStatus, "ready");
        verify(state.failureText(unsupported).indexOf("目前選的模型") >= 0);
        state.setError({data: {reason_code: "backend_unsupported"}});
        noModel();
        last("agent.runtime.get").ok(snapshot(4, data.reason));
        compare(state.errorText, state.failureText(unsupported));
        state.provider = Object.assign({}, account, {authenticated: false});
        compare(state.canLogin, true);
    }
    function test_known_matrix_data() {
        const rows = [];
        const reasons = {isolation_unavailable: "安全隔離", backend_binary_mismatch: "檔案不符合",
            backend_catalog_unavailable: "模型清單", backend_launch_failed: "AI 連線",
            launch_failed: "AI 對話", startup_timeout: "AI 對話", backend_exited: "已中斷", drain_timeout: "正常停止"};
        for (const reason in reasons) for (const provider of [null, Object.assign({}, account, {available: false}), account]) {
            for (const pid of [null, 42]) rows.push({tag: reason + "-" + (provider ? provider.available : "null") + "-" + pid,
                reason: reason, provider: provider, pid: pid, text: reasons[reason]});
        }
        return rows;
    }
    function test_known_matrix(data) {
        state.provider = data.provider;
        readRuntime(snapshot(5, data.reason, data.pid));
        unavailable();
        compare(state.aiStatus, "model_offline");
        verify(state.subscriptionUnavailableText.indexOf(data.text) >= 0, state.subscriptionUnavailableText);
        if (["launch_failed", "startup_timeout", "drain_timeout"].indexOf(data.reason) >= 0)
            verify(state.subscriptionUnavailableText.indexOf("API 金鑰") < 0);
    }
    function test_unknown() {
        readRuntime(snapshot(5, "future-unrecognised-code"));
        unavailable();
        verify(state.subscriptionUnavailableText.indexOf("future-") < 0);
        verify(state.subscriptionUnavailableText.indexOf("安裝或修復 Codex") < 0);
    }
    function test_runtime_read_lifecycle_data() {
        return ["unread", "pending", "failed"].map(kind => ({tag: kind, kind: kind}));
    }
    function test_runtime_read_lifecycle(data) {
        if (data.kind === "unread") state.runtime = null;
        else {
            state.refreshRuntime();
            if (data.kind === "failed") last("agent.runtime.get").fail({name: "timeout"});
        }
        compare(state.connected, false);
        compare(state.aiStatus, data.kind === "failed" ? "failed" : "pending");
        compare(state.chatStatus().connected, null);
        noModel();
        verify(state.failureText(unsupported).indexOf("安裝或修復 Codex") < 0);
        compare(state.canLogin, false);
    }
    function test_submit_generation_data() {
        const rows = [];
        for (const schedule of ["accepted-terminal", "terminal-reply", "rpc-error", "event-before-reply", "turn-read-before-reply"]) {
            for (const healthy of [false, true]) rows.push({tag: schedule + (healthy ? "-healthy" : "-refused"), schedule: schedule, healthy: healthy});
        }
        return rows;
    }
    function test_submit_generation(data) {
        state.draft = "fixture request";
        state.send();
        const submit = last("agent.turns.submit");
        compare(state.connected, false, "submit can ensure a new generation");
        noModel();
        if (data.schedule === "event-before-reply") {
            state.applyEvent({type: "conversation_updated", session_id: "session", turn_id: "turn", turn_state: "failed"});
            last("agent.turns.get").ok(unsupported);
        }
        if (data.schedule === "turn-read-before-reply") {
            state.refreshTurnFrom({data: {turn_id: "turn"}});
            last("agent.turns.get").ok(unsupported);
        }
        // Even an early G reply while submit is pending cannot authorize it.
        const early = client.pending.filter(call => call.method === "agent.runtime.get");
        if (early.length) early[early.length - 1].ok(snapshot(4, null));
        noModel();
        if (data.schedule === "rpc-error") submit.fail({data: {reason_code: "backend_unsupported"}});
        else submit.ok(data.schedule === "terminal-reply" ? unsupported : Object.assign({}, unsupported, {state: "queued", error_reason: null}));
        noModel();
        if (data.schedule === "event-before-reply" || data.schedule === "turn-read-before-reply") compare(state.turn.state, "failed", "queued reply cannot replace newer terminal readback");
        if (data.schedule !== "rpc-error" && data.schedule !== "terminal-reply") {
            state.applyEvent({type: "conversation_updated", session_id: "session", turn_id: "turn", turn_state: "failed"});
            last("agent.turns.get").ok(unsupported);
        }
        noModel();
        last("agent.runtime.get").ok(snapshot(5, data.healthy ? null : "isolation_unavailable", data.healthy ? 43 : null));
        if (data.healthy) {
            compare(state.connected, true);
            verify(state.failureText(unsupported).indexOf("目前選的模型") >= 0);
        } else {
            unavailable();
            verify(state.failureText(unsupported).indexOf("安全隔離") >= 0);
        }
        if (data.schedule === "rpc-error") compare(state.errorText, state.failureText(unsupported));
    }
    function test_rpc_error_revalidates_runtime() {
        state.setError({data: {reason_code: "backend_unsupported"}});
        noModel();
        last("agent.runtime.get").ok(snapshot(5, "isolation_unavailable", null));
        compare(state.errorText, state.failureText(unsupported));
        verify(state.errorText.indexOf("安全隔離") >= 0);
    }
    function test_old_readback_cannot_replace_current_error_data() {
        return ["page", "older-page", "turn"].map(kind => ({tag: kind, kind: kind}));
    }
    function test_old_readback_cannot_replace_current_error(data) {
        delete client.replies["agent.sessions.read"];
        if (data.kind === "turn") state.refreshTurnFrom({data: {turn_id: "turn"}});
        else if (data.kind === "older-page") { state.firstSeq = 60; state.loadOlder(); }
        else state.readNew();
        const old = last(data.kind === "turn" ? "agent.turns.get" : "agent.sessions.read");
        state.refreshSettings();
        last("agent.settings.describe").ok(prefs);
        // #137 brackets the account query with current runtime readback.
        last("agent.runtime.get").ok(snapshot(4, null));
        last("agent.providers.status").ok(account);
        state.setError({data: {reason_code: "backend_unsupported"}});
        last("agent.runtime.get").ok(snapshot(5, "isolation_unavailable", null));
        const text = state.errorText;
        if (old.fail) old.fail({name: "internal"});
        if (data.kind === "turn") old.ok(unsupported);
        else old.ok({events: [{seq: 60, type: "turn/end", data: {turn_id: "turn"}}]});
        compare(state.errorText, text);
        verify(state.errorText.indexOf("安全隔離") >= 0);
        unavailable();
    }
    function test_late_generation() {
        state.refreshRuntime();
        const old = last("agent.runtime.get");
        readRuntime(snapshot(5, "isolation_unavailable", null));
        old.ok(snapshot(4, null));
        unavailable();
        // A fresh request still cannot regress the observed generation.
        readRuntime(snapshot(4, null));
        compare(state.connected, false);
        noModel();
        readRuntime(snapshot(5, "isolation_unavailable", null));
        unavailable();
    }
    function test_context_fences_data() {
        return ["disconnect", "settings-pending", "settings-failed", "provider-switch", "patch", "disabled"].map(kind => ({tag: kind, kind: kind}));
    }
    function test_context_fences(data) {
        state.refreshRuntime();
        const oldRuntime = last("agent.runtime.get");
        state.refreshSettings();
        const oldSettings = last("agent.settings.describe");
        if (data.kind === "disconnect") { client.online = false; client.disconnected(); client.online = true; }
        if (data.kind === "settings-failed") oldSettings.fail({name: "internal"});
        if (data.kind === "provider-switch") {
            state.settings = Object.assign({}, prefs, {provider: "direct-model"});
            state.refreshProvider();
        }
        if (data.kind === "patch") state.chooseModel("other");
        if (data.kind === "disabled") state.setEnabled(false);
        oldRuntime.ok(snapshot(4, null));
        compare(state.connected, false);
        noModel();
        if (data.kind === "disconnect" || data.kind === "patch" || data.kind === "disabled") {
            oldSettings.ok(prefs);
            compare(state.connected, false, "old settings callback cannot revalidate runtime");
        }
    }
    function test_provider_ensure_fences_early_runtime() {
        state.refreshProvider();
        last("agent.runtime.get").ok(snapshot(4, null));
        compare(state.connected, false);
        last("agent.providers.status").ok(account);
        compare(state.connected, false);
        last("agent.runtime.get").ok(snapshot(5, "isolation_unavailable", null));
        unavailable();
    }
    function test_recovery() {
        readRuntime(snapshot(5, "future-code"));
        unavailable();
        readRuntime(snapshot(6, null, 43));
        compare(state.connected, true);
        compare(state.aiStatus, "ready");
        verify(state.failureText(unsupported).indexOf("目前選的模型") >= 0);
    }
    function test_direct_faults_data() {
        return ["isolation_unavailable", "backend_binary_mismatch", "backend_catalog_unavailable", "backend_launch_failed", "backend_exited",
            "launch_failed", "startup_timeout", "drain_timeout", "future-code"].map(reason => ({tag: reason, reason: reason, shared: ["launch_failed", "startup_timeout", "drain_timeout", "future-code"].indexOf(reason) >= 0}));
    }
    function test_direct_faults(data) {
        state.settings = Object.assign({}, prefs, {provider: "direct-model"});
        state.provider = Object.assign({}, account, {provider: "direct-model"});
        readRuntime(snapshot(5, data.reason, null));
        compare(state.connected, !data.shared);
        if (data.shared) {
            verify(state.stateText.indexOf("AI 對話") >= 0, state.stateText);
            verify(state.stateText.indexOf("API 金鑰") < 0);
            verify(state.failureText(unsupported).indexOf("API 金鑰") < 0);
        } else {
            verify(state.failureText(unsupported).indexOf("目前選的模型") >= 0);
        }
    }
    function test_sibling_surfaces_data() {
        return ["future-code", "isolation_unavailable", null].map(reason => ({tag: reason || "pending", reason: reason}));
    }
    function test_sibling_surfaces(data) {
        client.replies = Object.assign({}, client.replies, {"agent.settings.describe": prefs, "agent.providers.status": account});
        if (data.reason) client.replies["agent.runtime.get"] = snapshot(5, data.reason);
        const page = createTemporaryObject(settingsComponent, suite, {client: client, tokens: tokens, conversation: state, width: 800, height: 800});
        const chat = createTemporaryObject(chatComponent, suite, {client: client, tokens: tokens, conversation: state, width: 440, height: 800});
        const entry = createTemporaryObject(entryComponent, suite, {client: client, tokens: tokens, conversation: state});
        verify(page !== null && chat !== null && entry !== null);
        compare(state.connected, false);
        const line = find(page, item => item.objectName === "aiProviderStatus");
        verify(line.text.indexOf("已登入") < 0, line.text);
        if (data.reason) {
            compare(line.text, state.subscriptionUnavailableText);
            compare(chat.composerReason, line.text, "styled composer consumes the same failure projection");
            verify(find(chat, item => item.visible && item.text === line.text));
        }
        verify(chat.composerReason !== "登入模型後才能輸入。", chat.composerReason);
        compare(entry.Accessible.description, state.stateText);
        compare(find(chat, item => item.text === "使用 Codex 訂閱登入").visible, false);
        compare(find(chat, item => item.text === "送出").enabled, false);
    }
}
