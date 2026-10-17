import QtQuick
import QtTest
import DittoStub
import "../visual/.staged/assistant/shell/jelly" as Jelly
import "../visual/.staged/assistant/shell/chat" as Chat

TestCase {
    id: testCase
    name: "CompactPresentationMotion"
    width: 1280; height: 800
    visible: true
    when: windowShown
    Item { id: layer; width: 1280; height: 800 }
    Jelly.Tokens { id: tokens; appearance: ({ theme: "soft-jelly-light" }) }
    QtObject {
        id: client
        property bool online: true
        property var packages: []
        signal changeUpdated(var change)
        signal disconnected()
        function t(text) { return text; }
        function key(text, args) { return text; }
        function capabilityAvailable(name) { return false; }
    }
    Chat.ConversationState { id: conversation; client: client }
    Component { id: panelComponent; Chat.ChatPanel {} }
    property var panel: null
    function init() {
        StubDesktop.layer = layer;
        tokens.appearance = { theme: "soft-jelly-light" };
        conversation.draft = "fixture draft";
        conversation.turn = { turn_id: "fixture", state: "cancelling" };
    }
    function cleanup() { if (panel) panel.destroy(); panel = null; wait(10); }
    function mount(extra) {
        panel = panelComponent.createObject(testCase, Object.assign({ tokens: tokens, client: client,
            conversation: conversation, screen: { width: 1280, height: 800 },
            entryRect: { x: 1030, y: 714, width: 218, height: 54 } }, extra || {}));
        verify(!!panel);
        return findChild(layer, "chatPresentationContent");
    }
    function test_open_preference_reposition_and_destroy() {
        const frame = mount();
        wait(35);
        verify(frame.opacity > 0.92 && frame.opacity < 1);
        compare(frame.scale, 1); // control hit sizes never shrink
        verify(panel.focusedItem !== null, "focus does not wait for motion");
        tokens.appearance = { theme: "soft-jelly-light", reduced_motion: true };
        compare(frame.opacity, 1);
        compare(conversation.draft, "fixture draft");
        compare(conversation.turn.state, "cancelling");
        panel.entryRect = { x: 32, y: 64, width: 218, height: 54 };
        panel.corner = "top_left";
        compare(frame.opacity, 1);
        panel.destroy(); panel = null;
        wait(10);
        compare(conversation.draft, "fixture draft");
        compare(conversation.turn.state, "cancelling");
        // Fresh mount is the latest open intent; no delayed close completion.
        tokens.appearance = { theme: "soft-jelly-light" };
        const reopened = mount();
        tryCompare(reopened, "opacity", 1);
        verify(reopened.visible);
    }
    function test_legacy_and_hidden_settle() {
        const legacy = mount({ entryRect: null });
        compare(legacy.opacity, 1);
        panel.destroy(); panel = null;
        wait(10);
        const frame = mount();
        wait(30);
        verify(frame.opacity < 1);
        panel.visible = false;
        compare(frame.opacity, 1);
        compare(conversation.draft, "fixture draft");
    }
}
