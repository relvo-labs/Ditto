import QtQuick
import QtTest
import DittoStub
import Quickshell
import "../fixtures" as Fixtures

// #116 page-level behaviour with a candidate style, on the real centers,
// chat and approval files of a staged tree (`tree`, default the working copy;
// the RED run points it at the 87a2462 base). Tokens always come from the
// current tree so `uiStyle` exists. Fixture data, offscreen, no Core.
TestCase {
    id: testCase
    name: "UiStylePages"
    width: 1280
    height: 800
    visible: true
    when: windowShown

    property string tree: "current"
    readonly property url staged: Qt.resolvedUrl("../.staged/ui116/")

    Item { id: desktop; width: 1280; height: 800 }
    Fixtures.AppFixtureClient { id: client }
    Fixtures.ConversationFixture { id: offConversation; scene: "off" }
    Fixtures.ConversationFixture { id: activeConversation; scene: "active" }
    property var created: []

    function init() {
        StubDesktop.layer = desktop;
        Quickshell.environment = ({});
    }
    function cleanup() {
        for (const object of created) object.destroy();
        created = [];
        wait(0);
    }
    function make(path, properties, fromTree) {
        const component = Qt.createComponent(staged + (fromTree || tree) + "/" + path);
        verify(component.status === Component.Ready, component.errorString());
        const object = component.createObject(desktop, properties || {});
        verify(object !== null, path);
        created.push(object);
        return object;
    }
    function tokens(style) {
        const value = make("shell/jelly/Tokens.qml", { appearance: { theme: "soft-jelly-light", tokens: {}, locale: "zh-TW" } }, "current");
        value.uiStyle = style;
        return value;
    }
    function all(root, test) {
        const found = [];
        const walk = item => {
            for (const child of item.children) {
                if (test(child)) found.push(child);
                walk(child);
            }
        };
        walk(root);
        return found;
    }
    function shown(item) {
        for (let node = item; node; node = node.parent) {
            if (!node.visible) return false;
        }
        return true;
    }
    function texts(root) {
        return all(root, item => item.text !== undefined && item.font !== undefined && shown(item)).map(item => String(item.text));
    }
    function named(root, name, role) {
        return all(root, item => shown(item) && item.Accessible.name === name && (role === undefined || item.Accessible.role === role));
    }

    function test_composition_cards_have_two_main_actions_and_a_fixed_menu_data() {
        return ["j1", "j2", "j3"].map(style => ({ tag: style, style: style }));
    }
    function test_composition_cards_have_two_main_actions_and_a_fixed_menu(row) {
        const centers = make("shell/centers/Centers.qml", { client: client, tokens: tokens(row.style), conversation: offConversation, page: "composition" });
        tryVerify(() => all(centers, item => item.Accessible.role === Accessible.Grouping && item.Accessible.name === "開發").length > 0, 3000);
        waitForRendering(desktop);
        const menuX = [];
        for (const name of ["預設", "開發", "簡報"]) {
            const card = all(centers, item => item.Accessible.role === Accessible.Grouping && item.Accessible.name === name && item.radius !== undefined)[0];
            verify(card, name);
            const buttons = all(card, item => shown(item) && item.Accessible.role === Accessible.Button && item.activeFocusOnTab);
            verify(buttons.length <= 2, name + ": at most two main actions, got " + buttons.map(b => b.Accessible.name));
            const menus = all(card, item => shown(item) && item.Accessible.role === Accessible.ButtonMenu);
            compare(menus.length, 1, name + ": one ⋯ menu");
            menuX.push(Math.round(menus[0].mapToItem(centers, 0, 0).x));
            if (name !== "預設") compare(buttons.map(b => b.Accessible.name), ["試看", "使用這個組合"], name);
        }
        compare(menuX[1], menuX[0], "⋯ in the same place on every card");
        compare(menuX[2], menuX[0]);
        const items = all(centers, item => item.items !== undefined && item.triggered !== undefined)[0].items;
        const remove = items.find(item => item.id === "delete");
        verify(remove.danger === true, "delete is a danger item");
        compare(remove.enabled, false, "the composition in use cannot be deleted");
        verify(remove.reason.length > 0);
        for (const text of texts(centers)) verify(text.indexOf("✓") < 0, "no ✓ as a state: " + text);
        compare(texts(centers).filter(text => text === "Ditto").length, 0, "no second brand heading in the sidebar");
    }

    function test_centers_window_stays_clear_of_the_dock() {
        const centers = make("shell/centers/Centers.qml", { client: client, tokens: tokens("j1"), conversation: offConversation, screen: { height: 720 } });
        verify(centers.implicitHeight <= 720 - 148, "height " + centers.implicitHeight);
    }

    function test_chat_ai_off_is_one_empty_state_data() {
        return ["j1", "j2", "j3"].map(style => ({ tag: style, style: style }));
    }
    function test_chat_ai_off_is_one_empty_state(row) {
        offConversation.calls = [];
        const chat = make("shell/chat/ChatWindow.qml", { client: client, tokens: tokens(row.style), conversation: offConversation, assistantPresentation: true });
        waitForRendering(desktop);
        const all_ = texts(chat);
        compare(all_.filter(text => text === "Ditto 對話").length, 1, "one title");
        compare(all_.filter(text => /已關閉|目前關閉/.test(text)).length, 1, "AI off said once: " + all_.filter(text => /關閉/.test(text)));
        const cta = named(chat, "開啟 AI 對話", Accessible.Button);
        compare(cta.length, 1, "one primary call to action");
        mouseClick(cta[0]);
        compare(JSON.stringify(offConversation.calls), JSON.stringify([{ call: "setEnabled", args: true }]), "same Core path as before: " + JSON.stringify(offConversation.calls));
        verify(all_.filter(text => text.indexOf("把 Dock 移到左邊") >= 0).length === 1, "example phrases");
        verify(all_.indexOf("開啟 AI 對話後才能輸入。") >= 0, "the composer says why it is off");
        // Views and actions are apart: tabs are radio buttons, actions buttons.
        compare(named(chat, "對話", Accessible.RadioButton).length, 1);
        compare(named(chat, "歷史", Accessible.RadioButton).length, 1);
        compare(named(chat, "收合到角色旁", Accessible.Button).length, 1);
        compare(named(chat, "收合", Accessible.RadioButton).length, 0);
    }

    function test_approval_keeps_refusal_as_default_data() {
        return ["j1", "j2", "j3"].map(style => ({ tag: style, style: style }));
    }
    function test_approval_keeps_refusal_as_default(row) {
        const decisions = [];
        const properties = { client: client, tokens: tokens(row.style),
            approval: { request_id: "req", request: { capability_id: "desktop.windows.list", resource: "desktop.windows.read", purpose: "fixture" } } };
        let approval = make("shell/chat/ApprovalWindow.qml", properties);
        approval.decided.connect(decision => decisions.push(decision));
        waitForRendering(desktop);
        verify(approval.focusedItem !== null || true);
        const reject = named(approval, "拒絕", Accessible.Button)[0];
        tryVerify(() => reject.activeFocus, 1000, "refusing has the keyboard focus");
        keyClick(Qt.Key_Escape);
        compare(decisions, ["rejected"], "Escape refuses");
        const close = named(approval, "拒絕並關閉", Accessible.Button);
        compare(close.length, 1, "the window's one control refuses");
        verify(named(approval, "縮小視窗").length === 0 && named(approval, "放大視窗").length === 0);
        mouseClick(close[0]);
        compare(decisions, ["rejected", "rejected"]);
    }
}
