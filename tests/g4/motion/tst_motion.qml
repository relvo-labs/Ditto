import QtQuick
import QtTest
import "../../../shell/assistant" as Assistant
import "../../../shell/chat" as Chat
import "../../../shell/jelly" as Jelly

// Synthetic Core projection; rendered QML development evidence only.
TestCase {
    id: testCase
    name: "NativeMotion"
    width: 700
    height: 500
    visible: true
    when: windowShown
    Jelly.Tokens { id: tokens; appearance: ({ theme: "soft-jelly-light" }) }
    QtObject {
        id: client
        property bool online: true
        signal disconnected()
        function watchTopics(topics, event, resync, ready, error) {}
        function capability(method, params, ok, fail) {}
        function t(text) { return text; }
    }
    Chat.ConversationState { id: conversation; client: client }
    Assistant.AssistantEntry {
        id: entry
        x: 50; y: 50
        width: implicitWidth; height: implicitHeight
        tokens: tokens; client: client; conversation: conversation
    }
    MouseArea { id: other; x: 400; width: 50; height: 50; hoverEnabled: true }
    SignalSpy { id: activated; target: entry; signalName: "activated" }
    Jelly.MotionValue { id: value; duration: 180 }
    function init() {
        tokens.appearance = { theme: "soft-jelly-light" };
        entry.visible = true;
        entry.animations = true;
        entry.expanded = false;
        client.online = true;
        conversation.wanted = true;
        conversation.settings = { enabled: true };
        conversation.provider = { available: true, authenticated: true };
        conversation.turn = null;
        conversation.events = [];
        conversation.reconnecting = false;
        // The fixture client never answers capability(): a row that brings
        // client.online back (disconnect) starts a settings/runtime read that
        // would otherwise stay pending into the next row and clear
        // `connected`, so the working cue never starts (#164).
        conversation.settingsReading = false;
        conversation.providerReading = false;
        conversation.sending = false;
        conversation.runtimePending = false;
        conversation.runtimeFailed = false;
        other.forceActiveFocus();
        mouseMove(other, 20, 20, 10, Qt.NoButton);
        activated.clear();
        value.active = false;
        value.targetValue = 1;
        value.active = true;
        wait(200);
    }
    function symbol() { return entry.children[0]; }
    function test_press_reverse_and_immediate_action() {
        const visual = symbol();
        compare(visual.scale, 1);
        const rect = entry.mapToItem(testCase, 0, 0, entry.width, entry.height);
        mousePress(entry, 30, entry.height / 2);
        wait(45);
        verify(visual.scale < 0.999 && visual.scale > 0.89, "press must interpolate the rendered symbol");
        mouseRelease(entry, 30, entry.height / 2);
        compare(activated.count, 1); // never waits for settling
        mousePress(entry, 30, entry.height / 2);
        mouseRelease(entry, 30, entry.height / 2);
        compare(activated.count, 2);
        tryCompare(visual, "scale", 0.96); // pointer is still over the capsule
        compare(entry.mapToItem(testCase, 0, 0, entry.width, entry.height), rect);
        const image = grabImage(entry);
        verify(image.width > 0 && image.height > 0);
    }
    function test_latest_intent_and_long_frame() {
        value.targetValue = 0.90;
        wait(40);
        verify(value.value > 0.90 && value.value < 1);
        const before = value.value;
        value.targetValue = 1;
        verify(Math.abs(value.value - before) < 0.001, "reverse starts at the rendered value");
        value.targetValue = 0.96;
        value.targetValue = 1;
        // Deliberately stall QML for a long frame, then deliver the newest intent.
        const until = Date.now() + 100;
        while (Date.now() < until) {}
        value.targetValue = 0.94;
        tryCompare(value, "value", 0.94);
        compare(value.running, false);
        wait(220);
        compare(value.value, 0.94); // no old completion writes
    }
    function test_mid_motion_preference_data() {
        return [{ tag: "reduced-motion", pref: "reduced_motion" },
            { tag: "low-power", pref: "low_power_style" },
            { tag: "avatar-animations-off", pref: "animations" }];
    }
    function test_mid_motion_preference(data) {
        entry.forceActiveFocus();
        wait(30);
        verify(entry.feedbackRunning);
        if (data.pref === "animations") entry.animations = false;
        else {
            const appearance = { theme: "soft-jelly-light" };
            appearance[data.pref] = true;
            tokens.appearance = appearance;
        }
        compare(entry.feedbackRunning, false);
        compare(symbol().scale, 0.96);
        const text = entry.Accessible.description;
        keyClick(Qt.Key_Return);
        compare(activated.count, 1);
        compare(entry.Accessible.description, text);
    }
    function test_working_stop_data() {
        return ["cancelling", "succeeded", "failed", "partial", "unknown", "cancelled", "awaiting_approval",
            "disconnect", "reconnecting", "hidden", "reduced-motion"].map(state => ({ tag: state, state: state }));
    }
    function test_working_stop(data) {
        conversation.turn = { turn_id: "fixture-turn", state: "running" };
        verify(entry.workingCueRunning);
        wait(100);
        verify(symbol().opacity < 1);
        const state = data.state;
        if (state === "disconnect") client.online = false;
        else if (state === "reconnecting") conversation.reconnecting = true;
        else if (state === "hidden") entry.visible = false;
        else if (state === "reduced-motion") tokens.appearance = { theme: "soft-jelly-light", reduced_motion: true };
        else conversation.turn = { turn_id: "fixture-turn", state: state };
        compare(entry.workingCueRunning, false);
        compare(symbol().opacity, 1);
        compare(entry.workLevel, 1);
        wait(50);
        compare(entry.workLevel, 1);
        if (state === "hidden") {
            compare(conversation.turn.state, "running"); // hiding is not cancellation
            compare(entry.feedbackRunning, false);
            compare(symbol().scale, 1);
        }
        if (["partial", "unknown", "cancelled"].indexOf(state) >= 0)
            verify(entry.Accessible.description.indexOf(conversation.stateText) >= 0);
    }
    function test_fallback_equivalence_data() {
        return [{ tag: "normal", prefs: {} }, { tag: "reduced", prefs: { reduced_motion: true } },
            { tag: "solid", prefs: { reduced_transparency: true } },
            { tag: "low-power", prefs: { low_power_style: true } }];
    }
    function test_fallback_equivalence(data) {
        tokens.appearance = Object.assign({ theme: "soft-jelly-light" }, data.prefs);
        conversation.turn = { turn_id: "fixture-turn", state: "unknown" };
        const text = entry.Accessible.description;
        compare(text, conversation.stateText);
        entry.forceActiveFocus();
        keyClick(Qt.Key_Return);
        compare(activated.count, 1);
        compare(entry.width, entry.implicitWidth);
        compare(entry.height, entry.implicitHeight);
        mouseClick(entry, 1, 1);
        compare(activated.count, 1); // transparent corner still passes through
        verify(grabImage(entry).width > 0);
        compare(entry.Accessible.description, text);
        verify(!entry.workingCueRunning);
    }
}
