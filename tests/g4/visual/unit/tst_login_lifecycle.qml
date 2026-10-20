import QtQuick
import QtTest
import "../../../../shell/chat" as Chat

// Synthetic Core callbacks only. No live account, backend or device-code request.
TestCase {
    id: testCase
    name: "LoginLifecycle"
    when: windowShown
    QtObject {
        id: client
        property bool online: true
        property var requests: []
        property bool autoRuntime: true
        property int generation: 1
        property bool resultAvailable: true
        function capabilityAvailable(method) { return resultAvailable && method === "agent.providers.login_result"; }
        signal disconnected()
        function t(text) { return text; }
        function errorText(error) { return "safe fixture failure"; }
        function diagnosticText(error) { return "safe fixture diagnostic"; }
        function capability(method, params, ok, fail, options) {
            requests = requests.concat([{ method: method, params: params, ok: ok, fail: fail }]);
            if (method === "agent.runtime.get" && autoRuntime && ok)
                ok({ generation: generation, phase: "ready", isolation_verified: true });
        }
        function watchTopics(topics, onEvent, onResync, onReady, onError) {
            onReady({ subscription_id: "fixture-subscription" });
        }
    }
    Component { id: component; Chat.ConversationState {} }
    property var conversation: null
    readonly property var on: ({ enabled: true, provider: "codex-app-server", revision: 1 })
    readonly property var ready: ({ available: true, authenticated: true, provider: "codex-app-server", models: [], rate_limits: null })
    readonly property var signedOut: ({ available: true, authenticated: false, provider: "codex-app-server", models: [], rate_limits: null })
    readonly property var failure: ({ name: "internal", message: "synthetic", code: -32000 })
    function calls(method) { return client.requests.filter(r => r.method === method); }
    function latest(method) { const list = calls(method); verify(list.length > 0, method); return list[list.length - 1]; }
    function attempt() {
        return { login_id: "fixture-login", auth_url: "https://auth.openai.com/codex/device", user_code: "TEST-ONLY", expires_at_ms: Date.now() + 540000 };
    }
    function init() {
        client.online = true;
        client.requests = [];
        client.autoRuntime = true;
        client.generation = 1;
        client.resultAvailable = true;
        conversation = createTemporaryObject(component, testCase, { client: client });
        verify(conversation !== null);
        conversation.settings = on;
        conversation.runtime = { generation: 1, phase: "ready" };
        conversation.wanted = true;
    }
    function cleanup() {
        conversation.loginWatch.stop();
        conversation.providerRetry.stop();
    }
    function test_failed_completion_stops_waiting_and_preserves_confirmed_account() {
        conversation.provider = ready;
        conversation.login = attempt();
        conversation.loginWatch.start();
        conversation.loginWatch.triggered();
        const result = latest("agent.providers.login_result");
        result.ok({ login_id: conversation.login.login_id, generation: 1, state: "failed" });
        compare(conversation.login, null);
        verify(!conversation.loginWatch.running);
        verify(conversation.connected);
        compare(conversation.loginResultState, "failed");
        verify(conversation.loginResultText.length > 0);
    }
    function resultReply(state, id) { return { login_id: id || "fixture-login", generation: 1, state: state }; }
    function test_terminal_result_data() {
        return ["succeeded", "failed", "cancelled", "expired"].map(state => ({ tag: state, state: state }));
    }
    function test_terminal_result(data) {
        conversation.login = attempt();
        conversation.loginWatch.start(); conversation.loginWatch.triggered();
        latest("agent.providers.login_result").ok(resultReply(data.state));
        compare(conversation.login, null); verify(!conversation.loginWatch.running);
        compare(conversation.loginResultState, data.state);
        verify(!conversation.connected, "completion must not confirm account");
        if (data.state === "succeeded") {
            latest("agent.providers.status").fail(failure);
            verify(!conversation.connected); verify(conversation.loginResultText.length > 0);
            conversation.refreshProvider(); latest("agent.providers.status").ok(ready);
            verify(conversation.connected); compare(conversation.loginResultText, "");
        }
    }
    function test_pending_unknown_and_bad_wire_data() {
        return [
            { tag: "pending", value: resultReply("pending"), state: "pending" },
            { tag: "unknown", value: resultReply("unknown"), state: "unknown" },
            { tag: "bad-enum", value: resultReply("browser_confirmed"), state: "unknown" },
            { tag: "wrong-id", value: resultReply("failed", "other"), state: "unknown" },
            { tag: "wrong-generation", value: { login_id: "fixture-login", generation: 2, state: "failed" }, state: "unknown" },
            { tag: "extra-field", value: { login_id: "fixture-login", generation: 1, state: "failed", error: "SENSITIVE-LOGIN-SENTINEL" }, state: "unknown" },
            { tag: "missing-field", value: { login_id: "fixture-login", state: "failed" }, state: "unknown" }
        ];
    }
    function test_pending_unknown_and_bad_wire(data) {
        conversation.provider = ready; conversation.login = attempt();
        conversation.loginWatch.start(); conversation.loginWatch.triggered();
        latest("agent.providers.login_result").ok(data.value);
        compare(conversation.loginResultState, data.state);
        verify(conversation.login !== null); verify(conversation.loginWatch.running);
        verify(conversation.connected);
        verify(conversation.loginResultText.indexOf("SENSITIVE-LOGIN-SENTINEL") < 0);
        verify(conversation.errorDiagnostic.indexOf("SENSITIVE-LOGIN-SENTINEL") < 0);
    }
    function test_result_read_failure_and_old_catalog_preserve_existing_flow_data() { return [{ tag: "failed-read", old: false }, { tag: "old-catalog", old: true }]; }
    function test_result_read_failure_and_old_catalog_preserve_existing_flow(data) {
        client.resultAvailable = !data.old;
        conversation.provider = ready; conversation.login = attempt();
        conversation.loginWatch.start(); conversation.loginWatch.triggered();
        if (!data.old) latest("agent.providers.login_result").fail({ message: "SENSITIVE-LOGIN-SENTINEL", name: "unsupported" });
        else compare(calls("agent.providers.login_result").length, 0);
        compare(conversation.loginResultState, "unknown"); verify(conversation.connected);
        verify(conversation.login !== null); verify(conversation.loginWatch.running);
        compare(calls("agent.providers.login").length, 0);
        compare(calls("agent.providers.status").length, 1);
        verify(conversation.errorDiagnostic.indexOf("SENSITIVE-LOGIN-SENTINEL") < 0);
    }
    function test_result_poll_is_single_inflight() {
        conversation.login = attempt();
        conversation.loginWatch.triggered(); conversation.loginWatch.triggered(); conversation.loginWatch.triggered();
        compare(calls("agent.providers.login_result").length, 1);
        latest("agent.providers.login_result").ok(resultReply("pending"));
        conversation.loginWatch.triggered(); compare(calls("agent.providers.login_result").length, 2);
    }
    function test_terminal_result_context_reset_data() { return ["disabled", "provider"].map(kind => ({ tag: kind, kind: kind })); }
    function test_terminal_result_context_reset(data) {
        conversation.login = attempt(); conversation.refreshLoginResult();
        latest("agent.providers.login_result").ok(resultReply("failed"));
        compare(conversation.loginResultState, "failed");
        conversation.settings = data.kind === "disabled" ? { enabled: false, provider: "codex-app-server" } : { enabled: true, provider: "direct-model" };
        compare(conversation.loginResultState, "");
        compare(calls("agent.providers.cancel_login").length, 0);
    }
    function test_late_result_context_data() {
        const rows = [];
        for (const kind of ["cancel", "new-attempt", "disabled", "provider", "disconnect", "generation", "confirmed-account"])
            for (const fail of [false, true]) rows.push({ tag: kind + "-" + fail, kind: kind, fail: fail });
        return rows;
    }
    function test_late_result_context(data) {
        conversation.login = attempt(); conversation.loginWatch.triggered();
        const query = latest("agent.providers.login_result");
        if (data.kind === "cancel" || data.kind === "new-attempt") {
            conversation.cancelLogin();
            if (data.kind === "new-attempt") {
                conversation.startLogin(); const b = attempt(); b.login_id = "fixture-B";
                latest("agent.providers.login").ok(b);
            }
        }
        if (data.kind === "disabled") conversation.settings = { enabled: false, provider: "codex-app-server" };
        if (data.kind === "provider") conversation.settings = { enabled: true, provider: "direct-model" };
        if (data.kind === "disconnect") { client.online = false; client.disconnected(); }
        if (data.kind === "generation") { client.generation = 2; conversation.refreshRuntime(); }
        if (data.kind === "confirmed-account") latest("agent.providers.status").ok(ready);
        if (data.fail) query.fail({ message: "SENSITIVE-LOGIN-SENTINEL" }); else query.ok(resultReply("failed"));
        verify(conversation.loginResultState !== "failed");
        if (data.kind === "new-attempt") compare(conversation.login.login_id, "fixture-B");
        else compare(conversation.login, null);
        if (data.kind === "confirmed-account") verify(conversation.connected);
        verify(conversation.errorDiagnostic.indexOf("SENSITIVE-LOGIN-SENTINEL") < 0);
    }
    function test_expiry_after_await_data() { return ["result-success", "result-failure", "account", "cancel"].map(kind => ({ tag: kind, kind: kind })); }
    function test_expiry_after_await(data) {
        const a = attempt(); conversation.login = a; conversation.loginWatch.triggered();
        const query = latest("agent.providers.login_result"), account = latest("agent.providers.status");
        if (data.kind === "cancel") conversation.cancelLogin();
        // Same absolute deadline is moved in this synthetic callback fixture;
        // no timer is fired before the pending reply publishes.
        a.expires_at_ms = Date.now() - 1;
        if (data.kind === "result-success") query.ok(resultReply("succeeded"));
        if (data.kind === "result-failure") query.fail(failure);
        if (data.kind === "account") account.ok(ready);
        if (data.kind === "cancel") latest("agent.providers.cancel_login").ok({ completed: true });
        compare(conversation.loginResultState, "expired");
        compare(conversation.login, null); verify(!conversation.connected);
    }
    function test_cancel_ack_and_not_found_data() { return [{ tag: "cancelled", completed: true }, { tag: "unknown", completed: false }]; }
    function test_cancel_ack_and_not_found(data) {
        conversation.login = attempt(); conversation.cancelLogin();
        latest("agent.providers.cancel_login").ok({ completed: data.completed });
        compare(conversation.loginResultState, data.tag); verify(!conversation.connected);
        latest("agent.providers.status").ok(ready); verify(conversation.connected);
    }
    function test_poll_waits_for_the_outstanding_status() {
        conversation.login = attempt();
        conversation.loginWatch.triggered();
        conversation.loginWatch.triggered();
        conversation.loginWatch.triggered();
        compare(calls("agent.providers.status").length, 1);
        latest("agent.providers.status").ok(signedOut);
        conversation.loginWatch.triggered();
        compare(calls("agent.providers.status").length, 2);
    }
    function test_retry_timer_does_not_overlap_a_new_status_read() {
        conversation.refreshProvider();
        conversation.providerRetry.triggered();
        compare(calls("agent.providers.status").length, 1);
    }
    function test_start_keeps_the_confirmed_account_for_the_code_display() {
        conversation.provider = signedOut;
        conversation.startLogin();
        latest("agent.providers.login").ok(attempt());
        compare(conversation.provider, signedOut);
        verify(conversation.login !== null);
        verify(conversation.loginWatch.running);
    }
    function test_newer_read_wins_data() { return [{ tag: "late signed-out", fail: false }, { tag: "late failure", fail: true }]; }
    function test_newer_read_wins(data) {
        conversation.refreshProvider();
        const old = latest("agent.providers.status");
        conversation.refreshProvider();
        latest("agent.providers.status").ok(ready);
        verify(conversation.connected);
        if (data.fail) old.fail(failure); else old.ok(signedOut);
        verify(conversation.connected, "old status overwrote a newer account read");
    }
    function test_cancel_fences_status_and_reads_back_after_ack() {
        conversation.login = attempt();
        conversation.refreshProvider();
        const old = latest("agent.providers.status");
        conversation.cancelLogin();
        old.ok(ready);
        compare(conversation.login, null);
        compare(conversation.provider, null);
        latest("agent.providers.cancel_login").ok({ completed: true });
        verify(latest("agent.providers.status") !== old, "cancel did not read actual account state");
        latest("agent.providers.status").ok(signedOut);
        compare(conversation.provider.authenticated, false);
    }
    function test_context_change_fences_callbacks_data() {
        const rows = [];
        for (const kind of ["disabled", "provider", "disconnect", "generation"])
            for (const fail of [false, true]) rows.push({ tag: kind + "-" + fail, kind: kind, fail: fail });
        return rows;
    }
    function test_context_change_fences_callbacks(data) {
        conversation.login = attempt();
        conversation.refreshProvider();
        const old = latest("agent.providers.status");
        if (data.kind === "disabled") conversation.settings = { enabled: false, provider: "codex-app-server", revision: 2 };
        if (data.kind === "provider") conversation.settings = { enabled: true, provider: "direct-model", revision: 2 };
        if (data.kind === "disconnect") { client.online = false; client.disconnected(); }
        if (data.kind === "generation") {
            client.generation = 2;
            conversation.refreshRuntime();
        }
        if (data.fail) old.fail(failure); else old.ok(ready);
        compare(conversation.provider, null);
        compare(conversation.login, null);
        verify(!conversation.loginWatch.running);
        compare(conversation.providerFailed, false, "stale error became current failure");
    }
    function test_status_waits_for_matching_runtime_readback() {
        conversation.refreshProvider();
        client.autoRuntime = false;
        latest("agent.providers.status").ok(ready);
        compare(conversation.provider, null, "account accepted before generation readback");
        latest("agent.runtime.get").ok({ generation: 2, phase: "ready" });
        compare(conversation.provider, null);
        compare(conversation.runtime.generation, 2);
    }
    function test_expiry_cancels_the_same_attempt_without_claiming_signout() {
        const expired = attempt(); expired.expires_at_ms = Date.now() - 1;
        conversation.login = expired;
        conversation.loginWatch.triggered();
        compare(conversation.login, null);
        compare(calls("agent.providers.cancel_login").length, 1);
        compare(latest("agent.providers.cancel_login").params.login_id, expired.login_id);
        compare(conversation.provider, null);
    }
    function test_inactive_poll_does_not_call_provider_data() {
        return ["disabled", "provider", "disconnect"].map(kind => ({ tag: kind, kind: kind }));
    }
    function test_inactive_poll_does_not_call_provider(data) {
        conversation.login = attempt();
        if (data.kind === "disabled") conversation.settings = { enabled: false, provider: "codex-app-server" };
        if (data.kind === "provider") conversation.settings = { enabled: true, provider: "direct-model" };
        if (data.kind === "disconnect") { client.online = false; client.disconnected(); }
        conversation.loginWatch.triggered();
        compare(calls("agent.providers.status").length, 0);
    }
    function test_late_start_after_cancel_is_cleaned_without_displaying_code() {
        conversation.startLogin();
        const start = latest("agent.providers.login");
        conversation.cancelLogin();
        start.ok(attempt());
        compare(conversation.login, null);
        compare(calls("agent.providers.cancel_login").length, 1);
    }
    function test_old_settings_read_cannot_undo_a_disable() {
        conversation.refreshSettings();
        const read = latest("agent.settings.describe");
        conversation.setEnabled(false);
        latest("agent.settings.patch").ok({ enabled: false, provider: "codex-app-server", revision: 2 });
        read.ok(on);
        compare(conversation.settings.enabled, false);
    }
    function test_reconnect_reads_account_without_restarting_login() {
        conversation.refreshSettings();
        const oldSettings = latest("agent.settings.describe");
        client.online = false; client.disconnected(); client.generation = 2; client.online = true;
        latest("agent.settings.describe").ok(on);
        latest("agent.providers.status").ok(ready);
        verify(conversation.connected);
        oldSettings.fail(failure);
        verify(conversation.connected);
        compare(calls("agent.providers.login").length, 0);
    }
}
