import QtQuick
import QtTest
import "../../../../shell/assistant" as Assistant
import "../../../../shell/centers" as Centers
import "../../../../shell/chat" as Chat
import "../../../../shell/jelly" as Jelly

/// #81: an AI status that was not read, or whose read failed, is neither
/// "ready" nor "confirmed off/offline" — in the shared conversation text,
/// the assistant entry's accessible description, the chat report and the AI
/// settings switch. Fixture client only: no Core, no model, no Agent.
TestCase {
    id: testCase
    name: "AiStatus"
    width: 900
    height: 900
    visible: true
    when: windowShown

    /// Reads the open flow already makes. Anything else would be a new
    /// capability or a business action resent by a status read.
    readonly property var readCapabilities: ["agent.settings.describe", "agent.sessions.list",
        "agent.runtime.get", "agent.providers.status", "agent.sessions.read", "agent.turns.get"]

    QtObject {
        id: client
        property bool online: true
        property var calls: []
        /// method -> { ok: result } | { fail: error }; absent = no answer yet.
        property var replies: ({})
        signal disconnected()
        function t(text) { return text; }
        function key(text) { return text; }
        function capabilityAvailable(name) { return false; }
        function newKey(prefix) { return prefix + "-fixture"; }
        function errorText(error) { return error ? "fixture error " + error.name : ""; }
        function diagnosticText(error) { return error ? error.name + " (" + error.code + "): " + error.message : ""; }
        function capability(method, params, ok, fail, options) {
            calls = calls.concat([method]);
            const reply = replies[method];
            if (!reply) {
                return;
            }
            if (reply.fail) {
                if (fail) fail(reply.fail);
            } else if (ok) {
                ok(JSON.parse(JSON.stringify(reply.ok)));
            }
        }
        function watchTopics(topics, onEvent, onResync, onReady, onError) {
            onReady({ subscription_id: "fixture-subscription" });
        }
    }
    Jelly.Tokens { id: tokens }

    Component { id: conversationComponent; Chat.ConversationState {} }
    Component { id: entryComponent; Assistant.AssistantEntry {} }
    Component { id: settingsComponent; Centers.AISettings {} }

    readonly property var settingsOn: ({ enabled: true, revision: "fixture-r1", provider: "codex-app-server", approval_mode: "ask", model: null })
    readonly property var settingsOff: ({ enabled: false, revision: "fixture-r1", provider: "codex-app-server", approval_mode: "ask", model: null })
    readonly property var ready: ({ available: true, provider: "codex-app-server", authenticated: true, account_label: "fixture", models: [], rate_limits: null })

    function error(name) {
        return { name: name, code: -32000, message: "fixture " + name, data: name === "timeout" ? { outcome: "unknown" } : {} };
    }

    property var conversation: null
    property var entry: null

    function init() {
        client.online = true;
        client.calls = [];
        client.replies = {};
        conversation = createTemporaryObject(conversationComponent, testCase, { client: client });
        entry = createTemporaryObject(entryComponent, testCase, { client: client, tokens: tokens, conversation: conversation });
        verify(conversation !== null && entry !== null);
    }

    function answer(table) {
        client.replies = Object.assign({ "agent.sessions.list": { ok: { sessions: [] } } }, table);
    }
    function count(method) {
        return client.calls.filter(name => name === method).length;
    }
    function readsOnly() {
        for (const method of client.calls) {
            verify(readCapabilities.indexOf(method) >= 0, "unexpected call " + method);
        }
    }
    function find(item, test) {
        if (!item) return null;
        if (test(item)) return item;
        const kids = (item.children || []).concat(item.contentItem ? [item.contentItem] : []);
        for (const child of kids) {
            const found = find(child, test);
            if (found) return found;
        }
        return null;
    }
    function toggleOf(page) {
        return find(page, item => item.labelOn !== undefined && item.labelOff !== undefined);
    }
    function named(page, name) {
        return find(page, item => item.objectName === name);
    }
    function settingsPage() {
        const page = createTemporaryObject(settingsComponent, testCase,
            { y: 80, width: 800, height: 800, client: client, tokens: tokens, conversation: conversation });
        verify(page !== null);
        return page;
    }
    /// With settings unconfirmed the model line must not read as 尚未連線.
    function providerDeferred(page) {
        const line = named(page, "aiProviderStatus");
        verify(line, "no provider status line");
        if (!line.visible) return;
        verify(line.text.indexOf("尚未連線") < 0, "unconfirmed settings shown as disconnected: " + line.text);
        verify(line.text.indexOf("讀取 AI 設定後") >= 0, line.text);
    }
    /// The two ways a read happens again: the surface is opened again, or
    /// the connection to Core drops and comes back.
    function reread(kind) {
        if (kind === "reopen") {
            conversation.open();
        } else {
            client.online = false;
            client.disconnected();
            client.online = true;
        }
    }
    function report() {
        verify(typeof conversation.chatStatus === "function", "chatStatus() missing");
        return conversation.chatStatus();
    }

    // ---- settings -----------------------------------------------------------------
    function test_settings_unread() {
        answer({});
        conversation.open();
        compare(count("agent.settings.describe"), 1);
        compare(conversation.stateText, "待命中");
        compare(entry.Accessible.description, "待命中");
        const page = settingsPage();
        const toggle = toggleOf(page);
        verify(!(toggle && toggle.visible && !toggle.checked), "unread settings shown as 關");
        verify(!(toggle && toggle.visible && toggle.enabled), "unread settings can be switched");
        const status = named(page, "aiSettingsStatus");
        verify(status && status.visible, "no loading text");
        verify(status.text.indexOf("正在讀取") >= 0, status.text);
        compare(status.Accessible.name, status.text);
        verify(!named(page, "aiSettingsRetry").visible);
        providerDeferred(page);
        compare(conversation.aiStatus, "pending");
        const r = report();
        compare(r.state, null);
        compare(r.ai_status, "pending");
        compare(r.enabled, null);
        compare(r.connected, null);
        readsOnly();
    }

    function test_settings_failed_data() {
        return ["internal", "timeout", "permission_denied", "unavailable"].map(name => ({ tag: name, name: name }));
    }
    function test_settings_failed(data) {
        answer({ "agent.settings.describe": { fail: error(data.name) } });
        conversation.open();
        verify(conversation.stateText !== "待命中", "a failed read is shown as 待命中");
        verify(conversation.stateText.indexOf("無法讀取 AI 設定") >= 0, conversation.stateText);
        verify(conversation.stateText.indexOf("AI 對話已關閉") < 0);
        compare(entry.Accessible.description, conversation.stateText);
        compare(conversation.errorText, "fixture error " + data.name); // diagnostics kept
        verify(conversation.errorDiagnostic.indexOf(data.name) === 0);
        compare(conversation.taskState, "offline"); // controls and legacy avatar stay fail-closed
        compare(conversation.aiStatus, "failed");
        const r = report();
        compare(r.state, null);
        compare(r.ai_status, "failed");
        compare(r.enabled, null);
        compare(r.text, conversation.stateText);
        compare(count("agent.settings.describe"), 1);
        readsOnly();
    }

    function test_settings_failed_page() {
        answer({ "agent.settings.describe": { fail: error("internal") } });
        const page = settingsPage(); // the page's own open() reads settings
        compare(count("agent.settings.describe"), 1);
        const toggle = toggleOf(page);
        verify(!(toggle && toggle.visible && !toggle.checked), "failed settings shown as 關");
        verify(!(toggle && toggle.visible && toggle.enabled), "failed settings can be switched");
        const status = named(page, "aiSettingsStatus");
        verify(status && status.visible, "no failure text");
        verify(status.text.indexOf("無法讀取 AI 設定") >= 0, status.text);
        providerDeferred(page);
        const retry = named(page, "aiSettingsRetry");
        verify(retry && retry.visible);
        answer({ "agent.settings.describe": { ok: settingsOff } });
        retry.clicked();
        compare(count("agent.settings.describe"), 2);
        verify(!status.visible);
        verify(toggle.visible && toggle.enabled && !toggle.checked);
        readsOnly();
    }

    function test_settings_offline_page() {
        client.online = false;
        answer({ "agent.settings.describe": { fail: { name: "unavailable", code: -32007, message: "not connected", data: { reason: "participant_unavailable" } } } });
        const page = settingsPage();
        const status = named(page, "aiSettingsStatus");
        verify(status && status.visible);
        verify(status.text.indexOf("桌面服務未連線") >= 0, status.text);
        compare(conversation.aiStatus, "core_offline");
        readsOnly();
    }

    function test_confirmed_on_off_data() {
        return [{ tag: "on", on: true }, { tag: "off", on: false }];
    }
    function test_confirmed_on_off(data) {
        answer({ "agent.settings.describe": { ok: data.on ? settingsOn : settingsOff },
                 "agent.providers.status": { ok: ready } });
        conversation.open();
        const page = settingsPage();
        const toggle = toggleOf(page);
        verify(toggle.visible && toggle.enabled);
        compare(toggle.checked, data.on);
        verify(!named(page, "aiSettingsStatus").visible);
        const r = report();
        compare(r.enabled, data.on);
        if (data.on) {
            compare(conversation.aiStatus, "ready");
            compare(conversation.stateText, "可以描述想調整的桌面");
            compare(r.state, "idle");
            compare(r.connected, true);
        } else {
            compare(conversation.aiStatus, "disabled");
            verify(conversation.stateText.indexOf("AI 對話已關閉") >= 0);
            compare(r.state, "offline");
            compare(count("agent.providers.status"), 0); // off: the model is not contacted
        }
        compare(entry.Accessible.description, conversation.stateText);
        readsOnly();
    }

    /// F1: a read that fails after an earlier success is not confirmed by
    /// that earlier success — not ready, not off — until a read succeeds.
    function test_settings_lifecycle_data() {
        const rows = [];
        for (const kind of ["reopen", "reconnect"]) {
            for (const on of [true, false]) rows.push({ tag: kind + (on ? "-on" : "-off"), kind: kind, on: on });
        }
        return rows;
    }
    function test_settings_lifecycle(data) {
        const confirmed = { "agent.settings.describe": { ok: data.on ? settingsOn : settingsOff },
                            "agent.providers.status": { ok: ready } };
        answer(confirmed);
        conversation.open();
        const page = settingsPage();
        const toggle = toggleOf(page);
        const status = named(page, "aiSettingsStatus");
        compare(conversation.aiStatus, data.on ? "ready" : "disabled");
        verify(toggle.visible && toggle.enabled);

        answer({ "agent.settings.describe": { fail: error("internal") }, "agent.providers.status": { ok: ready } });
        reread(data.kind);
        compare(conversation.aiStatus, "failed");
        verify(conversation.stateText.indexOf("無法讀取 AI 設定") >= 0, conversation.stateText);
        compare(entry.Accessible.description, conversation.stateText);
        compare(conversation.enabled, false); // fail-closed controls
        let r = report();
        compare(r.state, null);
        compare(r.ai_status, "failed");
        compare(r.enabled, null);
        compare(r.text, conversation.stateText);
        verify(!(toggle.visible && toggle.enabled), "cached switch still usable after a failed read");
        verify(!toggle.visible, "cached switch still shown after a failed read");
        verify(status.visible && status.text.indexOf("無法讀取 AI 設定") >= 0, status.text);
        verify(named(page, "aiSettingsRetry").visible);
        providerDeferred(page);

        answer(confirmed);
        reread(data.kind);
        compare(conversation.aiStatus, data.on ? "ready" : "disabled");
        r = report();
        compare(r.state, data.on ? "idle" : "offline");
        compare(r.enabled, data.on);
        verify(toggle.visible && toggle.enabled);
        compare(toggle.checked, data.on);
        verify(!status.visible);
        compare(entry.Accessible.description, conversation.stateText);
        readsOnly();
    }

    function test_provider_lifecycle_data() {
        return [{ tag: "reopen", kind: "reopen" }, { tag: "reconnect", kind: "reconnect" }];
    }
    function test_provider_lifecycle(data) {
        answer({ "agent.settings.describe": { ok: settingsOn }, "agent.providers.status": { ok: ready } });
        conversation.open();
        const page = settingsPage();
        const line = named(page, "aiProviderStatus");
        compare(conversation.aiStatus, "ready");

        answer({ "agent.settings.describe": { ok: settingsOn }, "agent.providers.status": { fail: error("internal") } });
        reread(data.kind);
        compare(conversation.aiStatus, "failed");
        verify(conversation.stateText.indexOf("無法確認模型連線") >= 0, conversation.stateText);
        compare(entry.Accessible.description, conversation.stateText);
        let r = report();
        compare(r.state, null);
        compare(r.connected, null);
        compare(r.enabled, true);
        verify(line.text.indexOf("無法讀取模型連線狀態") >= 0, line.text);
        verify(named(page, "aiProviderRetry").visible);
        verify(toggleOf(page).visible && toggleOf(page).checked); // settings were confirmed

        answer({ "agent.settings.describe": { ok: settingsOn }, "agent.providers.status": { ok: ready } });
        reread(data.kind);
        compare(conversation.aiStatus, "ready");
        r = report();
        compare(r.state, "idle");
        compare(r.connected, true);
        verify(!named(page, "aiProviderRetry").visible);
        readsOnly();
    }

    /// After the connection to Core dropped, nothing read before counts:
    /// while the new reads are out the status is pending, not the old value.
    function test_reconnect_pending_is_not_stale() {
        answer({ "agent.settings.describe": { ok: settingsOn }, "agent.providers.status": { ok: ready } });
        conversation.open();
        compare(conversation.aiStatus, "ready");
        answer({});
        reread("reconnect");
        compare(count("agent.settings.describe"), 2);
        compare(conversation.aiStatus, "pending");
        compare(conversation.stateText, "待命中");
        compare(report().state, null);
        compare(report().enabled, null);
        compare(report().connected, null);
    }

    /// Reopening on the same live connection keeps what this connection
    /// confirmed until the new read answers, so a running turn does not
    /// flash offline (legacy avatar and entry unchanged). A failure clears it.
    function test_reopen_keeps_confirmed_until_answer() {
        answer({ "agent.settings.describe": { ok: settingsOn }, "agent.providers.status": { ok: ready } });
        conversation.open();
        conversation.turn = { turn_id: "fixture-turn", state: "running" };
        compare(conversation.taskState, "thinking");
        answer({});
        reread("reopen");
        compare(conversation.taskState, "thinking");
        compare(conversation.aiStatus, "ready");
        readsOnly();
    }

    // ---- provider status ----------------------------------------------------------
    function test_provider_unread() {
        answer({ "agent.settings.describe": { ok: settingsOn } });
        conversation.open();
        compare(count("agent.providers.status"), 1);
        compare(conversation.stateText, "待命中"); // neutral while the read is out
        compare(entry.Accessible.description, "待命中");
        compare(conversation.aiStatus, "pending");
        const r = report();
        compare(r.state, null);
        compare(r.enabled, true);
        compare(r.connected, null);
        const page = settingsPage();
        verify(toggleOf(page).checked);
        const status = named(page, "aiProviderStatus");
        verify(status.text.indexOf("正在讀取") >= 0, status.text);
        readsOnly();
    }

    /// Readback that says the model cannot be used now: confirmed, not a
    /// read failure.
    function test_provider_closed_data() {
        return [
            { tag: "unavailable-model", provider: { available: false, provider: "codex-app-server", authenticated: false, account_label: null, models: [], rate_limits: null }, status: "model_offline", text: "模型尚未連接" },
            { tag: "signed-out", provider: { available: true, provider: "codex-app-server", authenticated: false, account_label: null, models: [], rate_limits: null }, status: "model_offline", text: "模型尚未連接" },
            { tag: "core-disconnected", provider: null, status: "core_offline", text: "桌面服務未連線" },
            { tag: "ai-off", provider: null, status: "disabled", text: "AI 對話已關閉" }
        ];
    }
    function test_provider_closed(data) {
        answer({ "agent.settings.describe": { ok: data.tag === "ai-off" ? settingsOff : settingsOn },
                 "agent.providers.status": { ok: data.provider || ready } });
        conversation.open();
        if (data.tag === "core-disconnected") client.online = false;
        compare(conversation.aiStatus, data.status);
        verify(conversation.stateText.indexOf(data.text) >= 0, conversation.stateText);
        verify(conversation.stateText.indexOf("無法") < 0);
        compare(entry.Accessible.description, conversation.stateText);
        compare(conversation.taskState, "offline");
        const r = report();
        compare(r.state, "offline");
        compare(r.ai_status, data.status);
        readsOnly();
    }

    /// The existing "Agent still starting" path: one more read shortly,
    /// shown as still reading, never as a failure or as ready.
    function test_provider_starting_retry() {
        answer({ "agent.settings.describe": { ok: settingsOn },
                 "agent.providers.status": { fail: { name: "unavailable", code: -32007, message: "Agent is starting", data: { reason: "system_unavailable" } } } });
        conversation.open();
        compare(conversation.aiStatus, "pending");
        compare(conversation.stateText, "待命中");
        tryVerify(() => count("agent.providers.status") >= 2, 3000);
        compare(conversation.aiStatus, "pending");
        readsOnly();
    }

    function test_provider_failed_data() {
        return ["internal", "timeout", "permission_denied", "invalid_params"].map(name => ({ tag: name, name: name }));
    }
    function test_provider_failed(data) {
        answer({ "agent.settings.describe": { ok: settingsOn },
                 "agent.providers.status": { fail: error(data.name) } });
        conversation.open();
        verify(conversation.stateText !== "待命中", "a failed provider read is shown as 待命中");
        verify(conversation.stateText.indexOf("無法確認模型連線") >= 0, conversation.stateText);
        verify(conversation.stateText.indexOf("模型尚未連接") < 0); // not confirmed offline
        compare(entry.Accessible.description, conversation.stateText);
        compare(conversation.errorText, "fixture error " + data.name);
        verify(conversation.errorDiagnostic.indexOf(data.name) === 0);
        compare(conversation.taskState, "offline"); // still fail-closed
        compare(conversation.aiStatus, "failed");
        const r = report();
        compare(r.state, null);
        compare(r.ai_status, "failed");
        compare(r.enabled, true);
        compare(r.connected, null);
        // No automatic re-read and nothing resent behind the person's back.
        wait(1800);
        compare(count("agent.providers.status"), 1);
        readsOnly();
    }

    function test_provider_failed_page() {
        answer({ "agent.settings.describe": { ok: settingsOn },
                 "agent.providers.status": { fail: error("internal") } });
        const page = settingsPage();
        verify(toggleOf(page).checked); // the setting itself was read
        const status = named(page, "aiProviderStatus");
        verify(status.text.indexOf("無法讀取模型連線狀態") >= 0, status.text);
        const retry = named(page, "aiProviderRetry");
        verify(retry && retry.visible);
        answer({ "agent.settings.describe": { ok: settingsOn }, "agent.providers.status": { ok: ready } });
        retry.clicked();
        compare(count("agent.providers.status"), 2);
        compare(conversation.aiStatus, "ready");
        verify(!retry.visible);
        readsOnly();
    }

    /// A known terminal result stays next to the read failure.
    function test_terminal_result_with_failed_read() {
        answer({ "agent.settings.describe": { ok: settingsOn },
                 "agent.providers.status": { fail: error("internal") } });
        conversation.open();
        conversation.turn = { turn_id: "fixture-turn", state: "unknown" };
        verify(conversation.stateText.indexOf("結果尚未確認") >= 0, conversation.stateText);
        verify(conversation.stateText.indexOf("無法確認模型連線") >= 0, conversation.stateText);
        compare(entry.Accessible.description, conversation.stateText);
        readsOnly();
    }

    /// A draft waiting in the field is not sent by any status read or retry.
    function test_reads_do_not_send_draft() {
        answer({ "agent.settings.describe": { fail: error("internal") } });
        conversation.draft = "fixture draft";
        conversation.open();
        conversation.refreshSettings();
        answer({ "agent.settings.describe": { ok: settingsOn }, "agent.providers.status": { fail: error("timeout") } });
        conversation.refreshSettings();
        conversation.refreshProvider();
        compare(conversation.draft, "fixture draft");
        compare(count("agent.turns.submit"), 0);
        compare(count("agent.sessions.create"), 0);
        compare(count("agent.settings.patch"), 0);
        readsOnly();
    }
}
