import QtQuick
import QtTest
import "../../../../shell/assistant" as Assistant
import "../../../../shell/chat" as Chat
import "../../../../shell/jelly" as Jelly

TestCase {
    id: testCase
    name: "AssistantEntry"
    width: 900
    height: 700
    visible: true
    when: windowShown
    QtObject {
        id: client
        property bool online: true
        property int writes: 0
        property int reads: 0
        signal disconnected()
        function t(text) { return text; }
        function capability(method, params, ok, fail) {
            if (["agent.settings.describe", "agent.turns.get"].indexOf(method) >= 0) reads++;
            else writes++;
        }
        function watchTopics(topics, event, resync, ready, error) {
            reads++;
            ready({ subscription_id: "fixture-subscription" });
        }
    }
    Jelly.Tokens { id: tokens }
    Chat.ConversationState { id: conversation; client: client }
    Assistant.AssistantEntry {
        id: entry
        tokens: tokens
        client: client
        conversation: conversation
        width: implicitWidth
        height: implicitHeight
    }
    Chat.ChatInput {
        id: input
        y: 100
        tokens: tokens
        width: 300
        height: implicitHeight
    }
    SignalSpy { id: activated; target: entry; signalName: "activated" }
    SignalSpy { id: accepted; target: input; signalName: "accepted" }
    function init() {
        if (typeof entry.entryStyle === "string") {
            entry.entryStyle = "capsule";
            entry.labelExpanded = false;
        }
        entry.symbolVariant = "neutral";
        entry.expanded = false;
        tokens.appearance = { theme: "soft-jelly-light", tokens: {} };
        input.focusInput();
        activated.clear(); accepted.clear();
        conversation.wanted = false;
        conversation.subscriptionId = "";
        client.online = true;
        client.writes = 0; client.reads = 0;
        conversation.settings = null;
        conversation.provider = null;
        conversation.turn = null; conversation.events = []; conversation.runtime = null;
        conversation.reconnecting = false;
    }
    function readback() {
        conversation.wanted = true;
        conversation.settings = { enabled: true };
        conversation.provider = { available: true, authenticated: true };
    }
    function test_default_presentation_unchanged() {
        compare(entry.entryStyle, "capsule");
        compare(entry.symbolVariant, "neutral");
        compare(entry.implicitWidth, 218);
        compare(entry.implicitHeight, 54);
        compare(entry.Accessible.name, "開啟助理對話");
    }
    function test_fab_sizes_and_round_hit_data() {
        return [{ tag: "48", size: 48 }, { tag: "56", size: 56 }];
    }
    function test_fab_sizes_and_round_hit(data) {
        entry.entryStyle = "fab";
        entry.fabSize = data.size;
        entry.expansionMode = "chat";
        compare(entry.width, data.size);
        compare(entry.height, data.size);
        mouseClick(entry, 1, 1);
        compare(activated.count, 0);
        mouseClick(entry, data.size / 2, data.size / 2);
        compare(activated.count, 1);
    }
    function test_fab_label_keyboard_and_preserved_state() {
        readback();
        conversation.draft = "keep draft";
        conversation.streamText = "keep stream";
        conversation.turn = { turn_id: "pending", state: "awaiting_approval" };
        const turn = conversation.turn;
        entry.entryStyle = "fab";
        entry.expansionMode = "label";
        entry.forceActiveFocus();
        compare(entry.Accessible.name, "展開助理");
        keyClick(Qt.Key_Return);
        compare(entry.labelExpanded, true);
        compare(activated.count, 0);
        verify(entry.width >= 195);
        compare(entry.Accessible.name, "開啟助理對話");
        compare(entry.Accessible.description, conversation.stateText);
        keyClick(Qt.Key_Space);
        compare(activated.count, 1);
        keyClick(Qt.Key_Escape);
        compare(entry.labelExpanded, false);
        compare(conversation.turn, turn);
        compare(conversation.draft, "keep draft");
        compare(conversation.streamText, "keep stream");
        compare(client.writes, 0);
    }
    function test_fab_hover_focus_and_reduced_motion() {
        entry.entryStyle = "fab";
        entry.symbolVariant = "ditto-vector";
        entry.expansionMode = "chat";
        entry.forceActiveFocus();
        tryVerify(() => entry.feedbackRunning);
        tokens.appearance = { theme: "soft-jelly-light", tokens: {}, reduced_motion: true };
        compare(entry.feedbackRunning, false);
        compare(entry.children[0].scale, 0.96);
        mouseMove(entry, entry.width / 2, entry.height / 2);
        compare(entry.labelExpanded, false);
        compare(activated.count, 0);
        compare(client.reads, 0);
        compare(entry.Accessible.description, "待命中");
        keyClick(Qt.Key_Enter);
        compare(activated.count, 1);
    }
    function test_unknown_settings_after_open() {
        conversation.wanted = true;
        compare(conversation.stateText, "待命中");
        compare(entry.Accessible.description, "待命中");
        conversation.settings = { enabled: true };
        compare(conversation.stateText, "待命中"); // provider is also still unknown
        conversation.settings = { enabled: false };
        verify(entry.Accessible.description.indexOf("AI 對話已關閉") >= 0);
    }
    function test_preopen_data() {
        return [{ tag: "online", online: true }, { tag: "offline", online: false }];
    }
    function test_preopen(data) {
        conversation.settings = null;
        conversation.provider = null;
        conversation.wanted = false;
        client.online = data.online;
        const description = entry.Accessible.description;
        if (data.online) {
            compare(description, "待命中");
            verify(description.indexOf("關閉") < 0 && description.indexOf("未連線") < 0);
        } else {
            compare(description, "桌面服務未連線");
        }
        compare(client.writes, 0);
        compare(client.reads, 0);
    }
    function test_button_keys_and_candidates() {
        verify(!entry.activeFocus);
        compare(client.writes, 0); // idle does not start Agent or read context
        entry.forceActiveFocus();
        keyClick(Qt.Key_Return); keyClick(Qt.Key_Space); keyClick(Qt.Key_Enter);
        compare(activated.count, 3);
        entry.symbolVariant = "portrait";
        mouseClick(entry, entry.width / 2, entry.height / 2);
        compare(activated.count, 4);
        mouseClick(entry, 1, 1);
        compare(activated.count, 4); // transparent rounded corner is not a button
        entry.symbolVariant = "neutral";
    }
    function test_ime_policy_and_real_noncomposing_enter() {
        verify(!input.handlesKey(Qt.Key_Return, true));
        verify(!input.handlesKey(Qt.Key_Enter, true));
        verify(!input.handlesKey(Qt.Key_Escape, true));
        input.focusInput();
        keyClick(Qt.Key_Return);
        compare(accepted.count, 1);
        compare(input.composing, false);
    }
    function test_readback_states_data() {
        return [
            { tag: "idle", turn: null, phase: null, state: "idle" },
            { tag: "thinking", turn: "running", phase: null, state: "thinking" },
            { tag: "awaiting", turn: "awaiting_approval", phase: null, state: "awaiting" },
            { tag: "done", turn: "succeeded", phase: null, state: "done" },
            { tag: "failed", turn: "failed", phase: null, state: "failed" },
            { tag: "starting", turn: null, phase: "starting", state: "starting" },
            { tag: "partial", turn: "partial", phase: null, state: "failed" },
            { tag: "unknown", turn: "unknown", phase: null, state: "failed" },
            { tag: "stopped", turn: "cancelled", phase: null, state: "failed" },
            { tag: "cancelling", turn: "cancelling", phase: null, state: "thinking" }
        ];
    }
    function test_readback_states(data) {
        readback();
        conversation.turn = data.turn ? { turn_id: "fixture-turn", state: data.turn } : null;
        conversation.runtime = data.phase ? { phase: data.phase } : null;
        compare(conversation.taskState, data.state);
        verify(conversation.stateText.length > 0);
        compare(client.writes, 0);
    }
    function test_terminal_and_offline_reason_data() {
        const rows = [];
        for (const terminal of ["partial", "unknown", "cancelled"]) {
            for (const reason of ["core", "disabled", "provider"]) {
                rows.push({ tag: terminal + "-" + reason, terminal: terminal, reason: reason });
            }
        }
        return rows;
    }
    function test_terminal_and_offline_reason(data) {
        readback();
        conversation.turn = { turn_id: "fixture-terminal", state: data.terminal };
        const result = conversation.stateText;
        let reason;
        if (data.reason === "core") {
            client.online = false;
            reason = "桌面服務未連線";
        } else if (data.reason === "disabled") {
            conversation.settings = { enabled: false };
            reason = "AI 對話已關閉";
        } else {
            conversation.provider = { available: false, authenticated: false };
            reason = "模型尚未連接";
        }
        compare(conversation.taskState, "offline");
        verify(conversation.stateText.indexOf(result) >= 0);
        verify(conversation.stateText.indexOf(reason) >= 0);
        compare(entry.Accessible.description, conversation.stateText);
        compare(client.writes, 0);
    }
    function test_executing_and_terminal_offline() {
        readback();
        conversation.turn = { turn_id: "fixture-turn", state: "running" };
        conversation.events = [{ type: "tool/call", data: { turn_id: "fixture-turn", operation_id: "fixture-op" } }];
        compare(conversation.taskState, "executing");
        conversation.turn = { turn_id: "fixture-turn", state: "cancelling" };
        compare(conversation.stateText, "正在停止");
        for (const state of ["partial", "unknown", "cancelled"]) {
            conversation.turn = { turn_id: "fixture-turn", state: state };
            const result = conversation.stateText;
            client.online = false;
            verify(conversation.stateText.indexOf(result) >= 0);
            verify(conversation.stateText.indexOf("桌面服務未連線") >= 0);
            client.online = true;
        }
        conversation.turn = null;
        client.online = false;
        compare(conversation.taskState, "offline");
        conversation.reconnecting = true;
        verify(conversation.transportText.length > 0);
        compare(client.writes, 0); // displaying recovery never replays a tool
    }
}
