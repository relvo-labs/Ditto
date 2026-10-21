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
        function newKey(prefix) { return prefix + "-fixture"; }
        function errorText(error) { return "safe fixture failure"; }
        function diagnosticText(error) { return "safe fixture diagnostic"; }
        function capability(method, params, ok, fail, options) {
            const call = { method: method, params: params, done: false,
                ok: function (result) { call.done = true; if (ok) ok(result); },
                fail: function (error) { call.done = true; if (fail) fail(error); } };
            requests = requests.concat([call]);
            if (method === "agent.runtime.get" && autoRuntime)
                call.ok({ generation: generation, phase: "ready", backend_pid: 42, isolation_verified: true });
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
        conversation.runtime = { generation: 1, phase: "ready", backend_pid: 42, isolation_verified: true };
        conversation.provider = signedOut;
        conversation.wanted = true;
    }
    function cleanup() {
        conversation.loginWatch.stop();
        conversation.providerRetry.stop();
    }
    // review4: deterministic synthetic RPC scheduling through the production
    // settings/session/event path. These tests never call refreshProvider().
    function r3Frame(generation, failed) {
        return { generation: generation, phase: "ready", backend_pid: failed ? null : 42,
            isolation_verified: !failed, failure_reason: failed ? "backend_exited" : null };
    }
    function r3Observe(kind, history) {
        if (kind === "live-end") {
            if (history) history.ok({ events: [] });
            conversation.applyEvent({ type: "conversation_updated", session_id: conversation.sessionId,
                turn_id: "fixture-turn", turn_state: "succeeded" });
        } else {
            if (!history) { conversation.readNew(); history = latest("agent.sessions.read"); }
            history.ok({ events: [{ seq: 0, type: kind === "history-user" ? "user/message" : "turn/end",
                data: { turn_id: "fixture-turn" } }] });
        }
    }
    function r3Drain(authenticated, generation, failed) {
        // Bound deterministic fixture replies, not a wall-clock polling loop.
        // Exhaustion fails rather than hiding an accidental repeated-read loop.
        for (let i = 0; i < 20; i++) {
            const call = client.requests.find(r => !r.done && ["agent.runtime.get", "agent.providers.status", "agent.turns.get"].indexOf(r.method) >= 0);
            if (call) {
                if (call.method === "agent.runtime.get") call.ok(r3Frame(generation, failed));
                else if (call.method === "agent.providers.status") call.ok(authenticated ? ready : signedOut);
                else call.ok({ turn_id: "fixture-turn", state: "succeeded", created_at: "2026-10-21" });
            } else if (conversation.providerRetry.running) {
                conversation.providerRetry.stop(); conversation.providerRetry.triggered();
            } else return;
        }
        fail("fixture did not settle within its finite response schedule");
    }
    function test_r3_history_account_data() {
        const rows = [];
        for (const event of ["history-user", "history-end", "live-end"])
            for (const phase of ["pre-runtime", "status", "post-runtime"])
                for (const authenticated of [false, true])
                    rows.push({ tag: event + "-" + phase + "-" + authenticated, event: event, phase: phase, authenticated: authenticated });
        return rows;
    }
    function test_r3_history_account(data) {
        client.autoRuntime = false;
        conversation.refreshSettings();
        latest("agent.settings.describe").ok(on);
        latest("agent.sessions.list").ok({ sessions: [{ session_id: "fixture-session", next_seq: 1, created_at: "2026-10-21" }] });
        if (data.phase !== "pre-runtime") latest("agent.runtime.get").ok(r3Frame(1, false));
        if (data.phase === "post-runtime") latest("agent.providers.status").ok(data.authenticated ? ready : signedOut);
        r3Observe(data.event, latest("agent.sessions.read"));
        r3Drain(data.authenticated, 1, false);
        verify(conversation.provider !== null, "history abandoned the only account readback");
        compare(conversation.provider.authenticated, data.authenticated);
        compare(conversation.connected, data.authenticated);
        compare(conversation.canLogin, !data.authenticated);
        verify(!conversation.providerReading && !conversation.providerFailed && !conversation.providerRetry.running);
        compare(calls("agent.providers.status").length, 1, "same-generation observations must not restart account reads");
        compare(calls("agent.providers.login").length, 0);
    }
    function test_r3_observation_keeps_login_data() {
        const rows = [];
        for (const event of ["history-user", "history-end", "live-end"])
            for (const phase of ["pre-runtime", "login", "post-runtime", "bound"])
                rows.push({ tag: event + "-" + phase, event: event, phase: phase });
        return rows;
    }
    function test_r3_observation_keeps_login(data) {
        client.autoRuntime = false;
        conversation.sessionId = "fixture-session";
        conversation.startLogin();
        if (data.phase !== "pre-runtime") latest("agent.runtime.get").ok(r3Frame(1, false));
        const a = attempt(); a.login_id = "fixture-A";
        if (["post-runtime", "bound"].indexOf(data.phase) >= 0) latest("agent.providers.login").ok(a);
        if (data.phase === "bound") latest("agent.runtime.get").ok(r3Frame(1, false));
        const token = conversation.loginStart;
        r3Observe(data.event);
        compare(conversation.loginStart, token, "a read-only observation released the start owner");
        if (data.phase === "bound") compare(conversation.login, a);
        compare(calls("agent.providers.cancel_login").length, 0);
        r3Drain(false, 1, false);
        if (["pre-runtime", "login"].indexOf(data.phase) >= 0) latest("agent.providers.login").ok(a);
        r3Drain(false, 1, false);
        compare(conversation.login.login_id, "fixture-A");
        verify(conversation.loginWatch.running);
        compare(calls("agent.providers.cancel_login").length, 0);
    }
    function test_r3_operation_account_data() {
        const rows = [];
        for (const operation of ["runtime", "submit", "generation", "runtime-failure", "logout-failure"])
            for (const phase of ["pre-runtime", "status", "post-runtime"])
                for (const authenticated of [false, true])
                    rows.push({ tag: operation + "-" + phase + "-" + authenticated, operation: operation, phase: phase, authenticated: authenticated });
        return rows;
    }
    function test_r3_operation_account(data) {
        client.autoRuntime = false;
        conversation.refreshSettings(); latest("agent.settings.describe").ok(on);
        conversation.sessionId = "fixture-session";
        if (data.phase !== "pre-runtime") latest("agent.runtime.get").ok(r3Frame(1, false));
        if (data.phase === "post-runtime") latest("agent.providers.status").ok(data.authenticated ? ready : signedOut);
        if (data.operation === "runtime") conversation.invalidateRuntime();
        if (data.operation === "submit") {
            conversation.draft = "fixture request"; conversation.send();
            latest("agent.turns.submit").ok({ turn_id: "fixture-submit", state: "queued" });
        }
        if (data.operation === "generation" || data.operation === "runtime-failure") {
            // A confirmed runtime projection is the generation/failure fact;
            // pending reads below still pass through their request fences.
            conversation.runtime = r3Frame(data.operation === "generation" ? 2 : 1, data.operation === "runtime-failure");
        }
        if (data.operation === "logout-failure") {
            conversation.logout(); latest("agent.providers.logout").fail(failure);
        }
        r3Drain(data.authenticated, data.operation === "generation" ? 2 : 1, data.operation === "runtime-failure");
        verify(conversation.provider !== null, "an operation dropped account readback without recovery");
        compare(conversation.provider.authenticated, data.authenticated);
        compare(conversation.connected, data.authenticated && data.operation !== "runtime-failure");
        compare(conversation.canLogin, !data.authenticated && data.operation !== "runtime-failure");
        verify(!conversation.providerReading && !conversation.providerRetry.running);
        verify(calls("agent.providers.status").length <= (data.phase === "pre-runtime" ? 1 : 2), "overlapping recovery account reads");
    }
    function test_r3_terminal_account_data() {
        const rows = [];
        for (const outcome of ["failed", "cancelled", "expired"])
            for (const phase of ["pre-runtime", "status", "post-runtime"])
                for (const authenticated of [false, true])
                    rows.push({ tag: outcome + "-" + phase + "-" + authenticated, outcome: outcome, phase: phase, authenticated: authenticated });
        return rows;
    }
    function test_r3_terminal_account(data) {
        client.autoRuntime = false;
        conversation.refreshSettings(); latest("agent.settings.describe").ok(on);
        conversation.login = attempt();
        if (data.phase !== "pre-runtime") latest("agent.runtime.get").ok(r3Frame(1, false));
        if (data.phase === "post-runtime") latest("agent.providers.status").ok(data.authenticated ? ready : signedOut);
        conversation.refreshLoginResult();
        latest("agent.providers.login_result").ok(resultReply(data.outcome));
        r3Drain(data.authenticated, 1, false);
        verify(conversation.provider !== null, "terminal attempt abandoned independent account readback");
        compare(conversation.provider.authenticated, data.authenticated);
        compare(conversation.connected, data.authenticated);
        compare(conversation.canLogin, !data.authenticated);
        compare(conversation.login, null);
        verify(!conversation.providerReading && !conversation.providerRetry.running);
        compare(calls("agent.providers.status").length, 1);
    }
    function test_r3_cancel_start_account_data() {
        const rows = [];
        for (const phase of ["pre-runtime", "login", "post-runtime"])
            for (const authenticated of [false, true]) rows.push({ tag: phase + "-" + authenticated, phase: phase, authenticated: authenticated });
        return rows;
    }
    function test_r3_cancel_start_account(data) {
        client.autoRuntime = false; conversation.startLogin();
        if (data.phase !== "pre-runtime") latest("agent.runtime.get").ok(r3Frame(1, false));
        const a = attempt();
        const pendingLogin = data.phase === "login" ? latest("agent.providers.login") : null;
        if (data.phase === "post-runtime") latest("agent.providers.login").ok(a);
        conversation.cancelLogin();
        if (pendingLogin) pendingLogin.ok(a);
        r3Drain(data.authenticated, 1, false);
        verify(conversation.provider !== null, "cancelled start left no account readback");
        compare(conversation.connected, data.authenticated);
        compare(conversation.canLogin, !data.authenticated);
        compare(conversation.login, null); compare(conversation.loginStart, null);
        compare(calls("agent.providers.cancel_login").length, data.phase === "pre-runtime" ? 0 : 1);
    }
    // #134/#137 integration: availability evidence gates admission, and its
    // invalidation must finalize the same start owner as settings changes.
    function test_merge_login_admission_data() {
        return ["unavailable", "runtime-failure", "missing-backend", "signed-in", "unknown-account"]
            .map(kind => ({ tag: kind, kind: kind }));
    }
    function test_merge_login_admission(data) {
        if (data.kind === "unavailable") conversation.provider = { available: false, authenticated: false };
        if (data.kind === "runtime-failure") conversation.runtime = { generation: 1, phase: "ready", backend_pid: 42, isolation_verified: true, failure_reason: "backend_exited" };
        if (data.kind === "missing-backend") conversation.runtime = { generation: 1, phase: "ready", backend_pid: null, isolation_verified: false };
        if (data.kind === "signed-in") conversation.provider = ready;
        if (data.kind === "unknown-account") conversation.provider = null;
        verify(!conversation.canLogin);
        conversation.startLogin();
        compare(calls("agent.providers.login").length, 0, "canLogin=false must not issue authorization");
        compare(conversation.loginStart, null);
    }
    function test_merge_runtime_invalidation_data() {
        const rows = [];
        for (const phase of ["preflight", "login", "verification"])
            for (const source of ["runtime-failure", "missing-backend", "runtime-operation", "disconnect"])
                rows.push({ tag: phase + "-" + source, phase: phase, source: source });
        return rows;
    }
    function test_merge_runtime_invalidation(data) {
        client.autoRuntime = false;
        conversation.startLogin();
        let old = latest("agent.runtime.get");
        if (data.phase !== "preflight") {
            old.ok({ generation: 1, phase: "ready", backend_pid: 42, isolation_verified: true });
            old = latest("agent.providers.login");
        }
        const a = attempt(); a.login_id = "fixture-A";
        if (data.phase === "verification") {
            old.ok(a);
            old = latest("agent.runtime.get");
        }
        if (data.source === "runtime-failure") conversation.runtime = { generation: 1, phase: "ready", backend_pid: 42, isolation_verified: true, failure_reason: "backend_exited" };
        if (data.source === "missing-backend") conversation.runtime = { generation: 1, phase: "ready", backend_pid: null, isolation_verified: false };
        if (data.source === "runtime-operation") conversation.invalidateRuntime();
        if (data.source === "disconnect") { client.online = false; client.disconnected(); }
        compare(conversation.loginStart, null, "new runtime evidence must release the start synchronously");
        compare(conversation.login, null);
        compare(calls("agent.providers.cancel_login").length, data.phase === "verification" && data.source !== "disconnect" ? 1 : 0);
        client.autoRuntime = true;
        if (data.source === "disconnect") {
            client.online = true;
            latest("agent.settings.describe").ok(on);
        } else conversation.refreshProvider();
        latest("agent.providers.status").ok(signedOut);
        conversation.startLogin();
        const bStart = latest("agent.providers.login"), bToken = conversation.loginStart;
        verify(bToken !== null);
        old.ok(data.phase === "login" ? a : { generation: 1, phase: "ready", backend_pid: 42, isolation_verified: true });
        compare(conversation.loginStart, bToken);
        compare(conversation.login, null);
        const cancels = calls("agent.providers.cancel_login");
        compare(cancels.length, data.source !== "disconnect" && data.phase !== "preflight" ? 1 : 0);
        if (cancels.length) compare(cancels[0].params.login_id, "fixture-A");
        const b = attempt(); b.login_id = "fixture-B";
        bStart.ok(b);
        compare(conversation.login.login_id, "fixture-B");
        verify(conversation.loginWatch.running);
    }
    // review2: settings invalidation at each start await must release its owner,
    // even when refreshRuntime intentionally discards that owner's callback.
    function test_review2_start_invalidation_data() {
        const rows = [];
        for (const phase of ["preflight", "login", "verification"])
            for (const change of ["disable-enable", "provider-roundtrip"])
                for (const fail of [false, true])
                    rows.push({ tag: phase + "-" + change + (fail ? "-late-failure" : ""), phase: phase, change: change, fail: fail });
        return rows;
    }
    function test_review2_start_invalidation(data) {
        client.autoRuntime = false;
        conversation.startLogin();
        const preflight = latest("agent.runtime.get");
        const a = attempt(); a.login_id = "fixture-A";
        let start = null, verification = null;
        if (data.phase !== "preflight") {
            preflight.ok({ generation: 1, phase: "ready", backend_pid: 42, isolation_verified: true });
            start = latest("agent.providers.login");
        }
        if (data.phase === "verification") {
            start.ok(a);
            verification = latest("agent.runtime.get");
        }
        conversation.settings = data.change === "disable-enable"
            ? { enabled: false, provider: "codex-app-server", revision: 2 }
            : { enabled: true, provider: "direct-model", revision: 2 };
        conversation.settings = on;
        compare(calls("agent.providers.cancel_login").length, data.phase === "verification" ? 1 : 0,
            "an already returned id must be cleaned without waiting for a discarded callback");
        // Recovery must work before the invalidated callback ever returns.
        client.autoRuntime = true;
        conversation.refreshProvider();
        compare(calls("agent.providers.status").length, 1, "account readback is blocked by an abandoned start");
        latest("agent.providers.status").ok(signedOut);
        conversation.startLogin();
        const bStart = latest("agent.providers.login");
        verify(bStart !== start, "a new start must be admitted after settings return");
        const bToken = conversation.loginStart;
        verify(bToken !== null);
        // Deliver the old reply while B is still starting. It must neither
        // release B's token nor rebind A; returned A ids are cancelled once.
        const old = data.phase === "preflight" ? preflight : data.phase === "login" ? start : verification;
        if (data.fail) old.fail(failure);
        else old.ok(data.phase === "login" ? a : { generation: 1, phase: "ready", backend_pid: 42, isolation_verified: true });
        compare(conversation.loginStart, bToken);
        compare(conversation.login, null);
        const cancels = calls("agent.providers.cancel_login");
        compare(cancels.length, data.phase === "verification" || (data.phase === "login" && !data.fail) ? 1 : 0);
        if (cancels.length) compare(cancels[0].params.login_id, "fixture-A");
        const b = attempt(); b.login_id = "fixture-B";
        bStart.ok(b);
        compare(conversation.login.login_id, "fixture-B");
        verify(conversation.loginWatch.running);
        compare(conversation.loginStart, null);
        // Cleanup callbacks themselves cannot erase B or its account projection.
        for (const cancel of cancels) if (cancel.ok) cancel.ok({ completed: true });
        compare(conversation.login.login_id, "fixture-B");
        compare(conversation.provider, signedOut);
    }
    function test_review2_cancel_disconnect_release_data() {
        const rows = [];
        for (const phase of ["preflight", "login", "verification"])
            for (const exit of ["cancel", "disconnect"])
                rows.push({ tag: phase + "-" + exit, phase: phase, exit: exit });
        return rows;
    }
    function test_review2_cancel_disconnect_release(data) {
        client.autoRuntime = false;
        conversation.startLogin();
        if (data.phase !== "preflight") latest("agent.runtime.get").ok({ generation: 1, phase: "ready", backend_pid: 42, isolation_verified: true });
        if (data.phase === "verification") latest("agent.providers.login").ok(attempt());
        const old = latest(data.phase === "login" ? "agent.providers.login" : "agent.runtime.get");
        if (data.exit === "cancel") conversation.cancelLogin();
        else { client.online = false; client.disconnected(); }
        compare(conversation.loginStart, null, "exit releases without waiting for a callback");
        compare(calls("agent.providers.cancel_login").length,
            data.phase === "verification" && data.exit === "cancel" ? 1 : 0,
            "never replay an old connection's cancel into a new controller");
        client.autoRuntime = true;
        if (data.exit === "disconnect") {
            client.online = true;
            latest("agent.settings.describe").ok(on);
        } else conversation.refreshProvider();
        latest("agent.providers.status").ok(signedOut);
        conversation.startLogin();
        const bStart = latest("agent.providers.login"), bToken = conversation.loginStart;
        verify(bToken !== null);
        old.fail(failure);
        compare(conversation.loginStart, bToken, "old failure must not release B");
        const b = attempt(); b.login_id = "fixture-B";
        bStart.ok(b);
        compare(conversation.login.login_id, "fixture-B");
        compare(conversation.loginStart, null);
    }
    // review1 / authority v1.1: account truth and attempt expiry are independent.
    function test_review_expiry_account_data() {
        return [
            { tag: "row1-success-account-confirmed", success: true, authenticated: true },
            { tag: "row2-success-account-unconfirmed", success: true, authenticated: false },
            { tag: "row3-pending-account-confirmed", success: false, authenticated: true },
            { tag: "row4-pending-account-unconfirmed", success: false, authenticated: false }
        ];
    }
    function test_review_expiry_account(data) {
        const a = attempt(); conversation.login = a;
        if (data.success) {
            conversation.refreshLoginResult();
            latest("agent.providers.login_result").ok(resultReply("succeeded"));
        } else conversation.refreshProvider();
        const account = latest("agent.providers.status");
        // Synthetic absolute-deadline crossing while the callback is deferred.
        // No UI timer runs, and no real authorization or clock policy changes.
        a.expires_at_ms = Date.now() - 1;
        account.ok(data.authenticated ? ready : signedOut);
        compare(conversation.connected, data.authenticated);
        compare(conversation.login, null, "the code surface must be cleared");
        verify(!conversation.loginWatch.running);
        if (data.authenticated) compare(conversation.loginResultState, "", "confirmed account clears attempt outcome");
        else {
            compare(conversation.loginResultState, "expired");
            compare(conversation.provider, signedOut, "publish the fenced account readback, independently of expiry");
        }
    }
    function test_review_late_attempt_data() {
        return ["succeeded", "failed"].map(outcome => ({ tag: "row5-" + outcome, outcome: outcome }));
    }
    function test_review_late_attempt(data) {
        conversation.provider = ready;
        const a = attempt(); conversation.login = a;
        conversation.refreshLoginResult();
        const query = latest("agent.providers.login_result");
        a.expires_at_ms = Date.now() - 1;
        query.ok(resultReply(data.outcome));
        compare(conversation.login, null); verify(!conversation.loginWatch.running);
        compare(conversation.loginResultState, "expired");
        verify(conversation.connected, "an expired attempt reply must not erase an independently confirmed account");
    }
    function test_review_preaccount_expiry_data() { return [true, false].map(authenticated => ({ tag: authenticated ? "confirmed" : "unconfirmed", authenticated: authenticated })); }
    function test_review_preaccount_expiry(data) {
        client.autoRuntime = false;
        const a = attempt(); conversation.login = a;
        conversation.refreshProvider();
        a.expires_at_ms = Date.now() - 1;
        latest("agent.runtime.get").ok({ generation: 1, phase: "ready", backend_pid: 42, isolation_verified: true });
        compare(conversation.login, null, "clear expired code before awaiting the account");
        latest("agent.providers.status").ok(data.authenticated ? ready : signedOut);
        latest("agent.runtime.get").ok({ generation: 1, phase: "ready", backend_pid: 42, isolation_verified: true });
        compare(conversation.connected, data.authenticated); compare(conversation.login, null);
        compare(conversation.loginResultState, data.authenticated ? "" : "expired");
    }
    function test_review_expiry_preserves_inflight_account_data() { return [true, false].map(authenticated => ({ tag: authenticated ? "confirmed" : "unconfirmed", authenticated: authenticated })); }
    function test_review_expiry_preserves_inflight_account(data) {
        const a = attempt(); conversation.login = a; conversation.loginWatch.triggered();
        const account = latest("agent.providers.status"), query = latest("agent.providers.login_result");
        a.expires_at_ms = Date.now() - 1;
        query.ok(resultReply("succeeded")); // expires the attempt, never the official account read
        latest("agent.providers.cancel_login").ok({ completed: false });
        compare(calls("agent.providers.status").length, 1, "expiry cleanup must not overlap the existing account read");
        account.ok(data.authenticated ? ready : signedOut);
        compare(conversation.connected, data.authenticated); compare(conversation.login, null);
        compare(conversation.provider, data.authenticated ? ready : signedOut);
        compare(conversation.loginResultState, data.authenticated ? "" : "expired");
    }
    function test_review_expiry_ack_after_confirmed_account_data() { return [true, false].map(completed => ({ tag: completed ? "cancelled" : "notFound", completed: completed })); }
    function test_review_expiry_ack_after_confirmed_account(data) {
        conversation.login = attempt(); conversation.refreshProvider();
        const account = latest("agent.providers.status");
        conversation.expireLogin();
        const cancel = latest("agent.providers.cancel_login");
        account.ok(ready);
        verify(conversation.connected); compare(conversation.loginResultState, "");
        cancel.ok({ completed: data.completed });
        verify(conversation.connected); compare(conversation.loginResultState, "");
        compare(conversation.login, null); verify(!conversation.loginWatch.running);
    }
    function test_review_failed_account_after_expiry_data() {
        return [true, false].map(success => ({ tag: success ? "succeeded" : "pending", success: success }));
    }
    function test_review_failed_account_after_expiry(data) {
        conversation.provider = ready;
        const a = attempt(); conversation.login = a;
        if (data.success) {
            conversation.refreshLoginResult();
            latest("agent.providers.login_result").ok(resultReply("succeeded"));
        } else conversation.refreshProvider();
        a.expires_at_ms = Date.now() - 1;
        latest("agent.providers.status").fail(failure);
        compare(conversation.loginResultState, "expired");
        compare(conversation.provider, null); verify(!conversation.connected);
        compare(conversation.login, null); verify(!conversation.loginWatch.running);
    }
    function test_review_confirmation_context_data() {
        return ["new-attempt", "disabled", "provider", "disconnect", "generation"].map(kind => ({ tag: kind, kind: kind }));
    }
    function test_review_confirmation_context(data) {
        const a = attempt(); conversation.login = a;
        conversation.refreshLoginResult(); latest("agent.providers.login_result").ok(resultReply("succeeded"));
        const oldAccount = latest("agent.providers.status");
        if (data.kind === "new-attempt") {
            conversation.refreshProvider(); latest("agent.providers.status").ok(signedOut);
            conversation.startLogin(); const b = attempt(); b.login_id = "fixture-B";
            latest("agent.providers.login").ok(b);
        }
        if (data.kind === "disabled") conversation.settings = { enabled: false, provider: "codex-app-server" };
        if (data.kind === "provider") conversation.settings = { enabled: true, provider: "direct-model" };
        if (data.kind === "disconnect") { client.online = false; client.disconnected(); }
        if (data.kind === "generation") { client.generation = 2; conversation.runtime = r3Frame(2, false); }
        a.expires_at_ms = Date.now() - 1;
        oldAccount.ok(ready);
        verify(!conversation.connected, "a stale confirmation cannot publish account data");
        if (data.kind === "new-attempt") { compare(conversation.login.login_id, "fixture-B"); verify(conversation.loginWatch.running); }
        else compare(conversation.login, null);
        verify(conversation.loginResultState !== "expired", "stale deadline must not overwrite the new context");
    }
    function test_review_start_generation_data() {
        return [{ tag: "row6-stale-shell-snapshot", stale: true }, { tag: "row7-generation-moved-during-start", stale: false }];
    }
    function test_review_start_generation(data) {
        client.autoRuntime = false;
        conversation.startLogin();
        const preflightCount = calls("agent.runtime.get").length;
        // Accept both old/new request sequences to expose observable behavior,
        // not a missing helper or an assertion that merely demands a new call.
        if (preflightCount) latest("agent.runtime.get").ok({ generation: data.stale ? 2 : 1, phase: "ready", backend_pid: 42, isolation_verified: true });
        latest("agent.providers.login").ok(attempt());
        if (!data.stale) compare(conversation.login, null, "do not display a code before generation is verified");
        if (calls("agent.runtime.get").length > preflightCount)
            latest("agent.runtime.get").ok({ generation: 2, phase: "ready", backend_pid: 42, isolation_verified: true });
        if (data.stale) {
            conversation.refreshRuntime();
            latest("agent.runtime.get").ok({ generation: 2, phase: "ready", backend_pid: 42, isolation_verified: true });
            verify(conversation.login !== null, "same serving generation must keep its new attempt");
            verify(conversation.loginWatch.running);
            conversation.refreshLoginResult();
            compare(latest("agent.providers.login_result").params.generation, 2);
        } else {
            compare(conversation.login, null);
            verify(!conversation.loginWatch.running);
            compare(calls("agent.providers.cancel_login").length, 1, "clean up the unbound attempt through the existing cancel path");
            conversation.refreshLoginResult();
            compare(calls("agent.providers.login_result").length, 0);
        }
    }
    function test_review_start_read_failures_data() { return [{ tag: "preflight", after: false }, { tag: "verification", after: true }]; }
    function test_review_start_read_failures(data) {
        client.autoRuntime = false;
        conversation.startLogin();
        if (data.after) {
            latest("agent.runtime.get").ok({ generation: 1, phase: "ready", backend_pid: 42, isolation_verified: true });
            latest("agent.providers.login").ok(attempt());
        }
        latest("agent.runtime.get").fail(failure);
        compare(conversation.login, null); compare(conversation.loginStart, null);
        verify(!conversation.loginWatch.running);
        compare(calls("agent.providers.login").length, data.after ? 1 : 0);
        compare(calls("agent.providers.cancel_login").length, data.after ? 1 : 0);
    }
    function test_review_start_status_does_not_steal_runtime_identity() {
        client.autoRuntime = false;
        conversation.startLogin();
        const before = latest("agent.runtime.get");
        conversation.refreshProvider(); conversation.providerRetry.triggered();
        compare(calls("agent.runtime.get").length, 1);
        before.ok({ generation: 2, phase: "ready", backend_pid: 42, isolation_verified: true });
        latest("agent.providers.login").ok(attempt());
        const after = latest("agent.runtime.get");
        conversation.refreshProvider(); conversation.providerRetry.triggered();
        compare(calls("agent.runtime.get").length, 2);
        after.ok({ generation: 2, phase: "ready", backend_pid: 42, isolation_verified: true });
        verify(conversation.login !== null); verify(conversation.loginWatch.running);
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
        compare(conversation.provider, ready, "attempt failure preserves independent account data");
        compare(conversation.loginResultState, "failed");
        verify(conversation.loginResultText.length > 0);
        latest("agent.providers.status").ok(ready);
        verify(conversation.connected, "the pending official account read must still complete");
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
        compare(conversation.provider, ready, "pending result preserves the independently confirmed account data");
        verify(conversation.loginResultText.indexOf("SENSITIVE-LOGIN-SENTINEL") < 0);
        verify(conversation.errorDiagnostic.indexOf("SENSITIVE-LOGIN-SENTINEL") < 0);
        latest("agent.providers.status").ok(ready);
        verify(conversation.connected, "a fresh authoritative account still confirms the preserved session");
    }
    function test_result_read_failure_and_old_catalog_preserve_existing_flow_data() { return [{ tag: "failed-read", old: false }, { tag: "old-catalog", old: true }]; }
    function test_result_read_failure_and_old_catalog_preserve_existing_flow(data) {
        client.resultAvailable = !data.old;
        conversation.provider = ready; conversation.login = attempt();
        conversation.loginWatch.start(); conversation.loginWatch.triggered();
        if (!data.old) latest("agent.providers.login_result").fail({ message: "SENSITIVE-LOGIN-SENTINEL", name: "unsupported" });
        else compare(calls("agent.providers.login_result").length, 0);
        compare(conversation.loginResultState, "unknown");
        compare(conversation.provider, ready, "unknown result does not erase account data during a fresh runtime read");
        verify(conversation.login !== null); verify(conversation.loginWatch.running);
        compare(calls("agent.providers.login").length, 0);
        compare(calls("agent.providers.status").length, 1);
        verify(conversation.errorDiagnostic.indexOf("SENSITIVE-LOGIN-SENTINEL") < 0);
        latest("agent.providers.status").ok(ready);
        verify(conversation.connected, "a fresh authoritative account still confirms the preserved session");
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
                conversation.refreshProvider(); latest("agent.providers.status").ok(signedOut);
                conversation.startLogin(); const b = attempt(); b.login_id = "fixture-B";
                latest("agent.providers.login").ok(b);
            }
        }
        if (data.kind === "disabled") conversation.settings = { enabled: false, provider: "codex-app-server" };
        if (data.kind === "provider") conversation.settings = { enabled: true, provider: "direct-model" };
        if (data.kind === "disconnect") { client.online = false; client.disconnected(); }
        if (data.kind === "generation") { client.generation = 2; conversation.runtime = r3Frame(2, false); }
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
        if (data.kind === "account") account.ok(signedOut); // v1.1: authenticated counterpart is review row3
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
            conversation.runtime = r3Frame(2, false);
        }
        if (data.fail) old.fail(failure); else old.ok(ready);
        compare(conversation.provider, data.kind === "generation" ? signedOut : null,
            "a late callback cannot replace the retained signed-out readback");
        verify(!conversation.connected);
        compare(conversation.login, null);
        verify(!conversation.loginWatch.running);
        compare(conversation.providerFailed, false, "stale error became current failure");
    }
    function test_status_waits_for_matching_runtime_readback() {
        conversation.provider = null;
        conversation.refreshProvider();
        client.autoRuntime = false;
        latest("agent.providers.status").ok(ready);
        compare(conversation.provider, null, "account accepted before generation readback");
        latest("agent.runtime.get").ok({ generation: 2, phase: "ready", backend_pid: 42, isolation_verified: true });
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
        compare(conversation.provider, signedOut, "expiry does not erase the account readback");
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
