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
