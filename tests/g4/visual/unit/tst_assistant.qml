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
        signal disconnected()
        function t(text) { return text; }
        function capability(method, params, ok, fail) { writes++; }
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
        input.focusInput();
        activated.clear(); accepted.clear(); client.writes = 0;
        client.online = true;
        conversation.settings = { enabled: true };
        conversation.provider = { available: true, authenticated: true };
        conversation.turn = null; conversation.events = []; conversation.runtime = null;
        conversation.reconnecting = false;
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
        conversation.turn = data.turn ? { turn_id: "fixture-turn", state: data.turn } : null;
        conversation.runtime = data.phase ? { phase: data.phase } : null;
        compare(conversation.taskState, data.state);
        verify(conversation.stateText.length > 0);
        compare(client.writes, 0);
    }
    function test_executing_and_terminal_offline() {
        conversation.turn = { turn_id: "fixture-turn", state: "running" };
        conversation.events = [{ type: "tool/call", data: { turn_id: "fixture-turn", operation_id: "fixture-op" } }];
        compare(conversation.taskState, "executing");
        conversation.turn = { turn_id: "fixture-turn", state: "cancelling" };
        compare(conversation.stateText, "正在停止");
        for (const state of ["partial", "unknown", "cancelled"]) {
            conversation.turn = { turn_id: "fixture-turn", state: state };
            const result = conversation.stateText;
            client.online = false;
            compare(conversation.stateText, result);
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
