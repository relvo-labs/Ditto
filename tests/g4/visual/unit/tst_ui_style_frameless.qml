import QtQuick
import QtTest
import DittoStub
import Quickshell
import "../fixtures" as Fixtures

// PR #117 repair 2: a Ditto window's FramelessWindowHint changes only while
// the window is not shown. Changing it on a shown window let Qt's render
// thread blit a title bar from a content buffer that was never made, and the
// Shell crashed (VM, 2026-10-20 13:03 UTC; see shell/ui/WindowHeader.qml).
//
// The real Centers, ChatWindow and ApprovalWindow of a staged tree
// (`tree`: "current-native" is the working copy; a RED run points it at an
// older ref staged by `node stage-ui116.mjs <ref>`) run on DittoStub's
// StubFloatingWindow: a real offscreen backing window that joins the content
// and is shown the way Quickshell 0.3.1 does it, and records every change of
// its flags with whether it was shown. Tokens always come from the current
// tree. Fixture data, offscreen: development evidence. Whether Qt and Wayfire
// draw one title on the target session is the coordinator's VM check.
TestCase {
    id: testCase
    name: "UiStyleFrameless"
    when: windowShown

    property string tree: "current-native"
    readonly property url staged: Qt.resolvedUrl("../.staged/ui116/")

    Fixtures.AppFixtureClient { id: client }
    Fixtures.ConversationFixture { id: conversation; scene: "off" }
    property var created: []
    property var events: []

    function init() {
        Quickshell.environment = ({});
        client.calls = [];
        client.reads = [];
        client.appearanceTokens = { accent: "#b9a4ff" };
        events = [];
    }
    function cleanup() {
        for (let i = created.length - 1; i >= 0; i--) {
            if (created[i] && typeof created[i].destroy === "function") created[i].destroy();
        }
        created = [];
        wait(0);
    }

    readonly property var dark: ({ theme: "soft-jelly", tokens: {}, locale: "zh-TW" })
    readonly property var noTheme: ({ tokens: {}, locale: "zh-TW" })
    function light(style) {
        return { theme: "soft-jelly-light", tokens: { accent: "#b9a4ff", ui_style: style || "j1" }, locale: "zh-TW" };
    }
    function tokensWith(appearance) {
        const component = Qt.createComponent(staged + "current/shell/jelly/Tokens.qml");
        verify(component.status === Component.Ready, component.errorString());
        const tokens = component.createObject(testCase, { appearance: appearance });
        created.push(tokens);
        return tokens;
    }

    // Each window as shell.qml creates it, with the signals that would mean
    // "closed" or "refused" recorded: a change of style is neither.
    readonly property var windows: [
        { tag: "centers", path: "shell/centers/Centers.qml", signal: "closeRequested",
          properties: () => ({ client: client, conversation: conversation, page: "personalization" }) },
        { tag: "chat", path: "shell/chat/ChatWindow.qml", signal: "closeRequested",
          properties: () => ({ client: client, conversation: conversation }) },
        { tag: "approval", path: "shell/chat/ApprovalWindow.qml", signal: "decided",
          properties: () => ({ client: client, approval: { request_id: "req", request: {
              capability_id: "desktop.windows.list", resource: "desktop.windows.read", purpose: "fixture" } } }) }
    ]
    function open(kind, tokens, initialFlags) {
        const component = Qt.createComponent(staged + tree + "/" + kind.path);
        verify(component.status === Component.Ready, component.errorString());
        const properties = Object.assign({ tokens: tokens }, kind.properties());
        if (initialFlags !== undefined) properties.initialFlags = initialFlags;
        const win = component.createObject(testCase, properties);
        verify(win !== null, kind.path);
        created.push(win);
        win[kind.signal].connect(() => testCase.events.push(kind.signal));
        win.closed.connect(() => testCase.events.push("closed"));
        tryVerify(() => win.connected && win.backingWindow.visible, 3000, "the window is shown");
        return win;
    }

    function each(rows) {
        return [].concat(...windows.map(rows));
    }
    function frameless(win) {
        return (win.backingWindow.flags & Qt.FramelessWindowHint) !== 0;
    }
    // The invariant: no flag change on a shown window, the window is shown
    // after the change, and it was not closed or refused by it.
    function expectSafe(win, label) {
        const onShown = win.flagWrites.filter(write => write.shown);
        compare(JSON.stringify(onShown), "[]", label + ": flags changed while the window was shown");
        verify(win.visible && win.backingWindow.visible, label + ": the window is shown again");
        compare(JSON.stringify(events), "[]", label + ": a change of style does not close or refuse");
    }
    function step(win, tokens, appearance, styled, label) {
        tokens.appearance = appearance;
        wait(0);
        expectSafe(win, label);
        compare(frameless(win), styled, label + (styled ? ": Ditto draws the one title" : ": Qt's title bar is back"));
    }

    function test_first_show_data() {
        return each(kind => [
            { tag: kind.tag + "/styled", kind: kind, appearance: light("j1"), styled: true },
            { tag: kind.tag + "/dark", kind: kind, appearance: dark, styled: false },
            { tag: kind.tag + "/no-theme", kind: kind, appearance: noTheme, styled: false }]);
    }
    // The flag is decided before the window is first shown: never a change
    // on the shown window, and the window is shown once (no flash).
    function test_first_show(row) {
        const win = open(row.kind, tokensWith(row.appearance));
        expectSafe(win, "first show");
        compare(frameless(win), row.styled);
        compare(win.maps, 1, "shown once");
    }

    function test_style_changes_data() {
        return windows.map(kind => ({ tag: kind.tag, kind: kind }));
    }
    // J1 → J2 → J3 keep Ditto's title: no flag change, no re-show. Off and
    // on again changes the flag only with the window hidden, then shows it.
    function test_style_changes(row) {
        const tokens = tokensWith(light("j1"));
        const win = open(row.kind, tokens);
        const writes = win.flagWrites.length;
        step(win, tokens, light("j2"), true, "J1→J2");
        step(win, tokens, light("j3"), true, "J2→J3");
        compare(win.flagWrites.length, writes, "between styles the flags are not touched");
        compare(win.maps, 1, "between styles the window is not shown again");
        step(win, tokens, dark, false, "J3→off");
        compare(win.maps, 2, "off: hidden, changed, shown again");
        step(win, tokens, light("j1"), true, "off→J1");
        compare(win.maps, 3);
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
    function test_hide_and_show_keeps_the_window_data() {
        return windows.map(kind => ({ tag: kind.tag, kind: kind }));
    }
    // Hidden and shown again, the window is the same window: the page, an
    // unsent draft, the pending request and the focused control are kept.
    function test_hide_and_show_keeps_the_window(row) {
        const tokens = tokensWith(light("j1"));
        const win = open(row.kind, tokens);
        let draft = null;
        if (row.kind.tag === "centers") {
            win.page = "history";
            const tab = all(win.contentItem, item => item.Accessible.role === Accessible.PageTab && item.Accessible.name === "變更紀錄")[0];
            verify(tab, "the history tab");
            tab.forceActiveFocus(Qt.TabFocusReason);
        } else if (row.kind.tag === "chat") {
            draft = all(win.contentItem, item => typeof item.focusInput === "function" && typeof item.text === "string")[0];
            verify(draft, "the composer");
            draft.text = "還沒送出的草稿";
        }
        tryVerify(() => win.focusedItem !== null, 1000, "a control has focus");
        const focused = win.focusedItem;
        for (const [appearance, styled, label] of [[dark, false, "off"], [light("j3"), true, "on"]]) {
            step(win, tokens, appearance, styled, label);
            tryCompare(win, "focusedItem", focused, 1000, label + ": focus is on the same control");
            if (row.kind.tag === "centers") compare(win.page, "history", label + ": same page");
            if (draft) compare(draft.text, "還沒送出的草稿", label + ": the draft is kept");
            if (row.kind.tag === "approval") compare(win.approval.request_id, "req", label + ": same request, not decided");
        }
        compare(win.maps, 3, "hidden and shown once per change");
    }

    function test_undo_and_theme_switch_data() {
        return each(kind => [
            { tag: kind.tag + "/undo", kind: kind, sequence: [
                [light("j2"), true, "undo J3→J2"], [noTheme, false, "undo to no theme"], [light("j3"), true, "redo"]] },
            { tag: kind.tag + "/theme", kind: kind, sequence: [
                [dark, false, "light→dark"], [light("j3"), true, "dark→light"], [dark, false, "light→dark again"]] }]);
    }
    function test_undo_and_theme_switch(row) {
        const tokens = tokensWith(light("j3"));
        const win = open(row.kind, tokens);
        for (const [appearance, styled, label] of row.sequence) step(win, tokens, appearance, styled, label);
    }

    function test_flags_set_elsewhere_are_kept_data() {
        const rows = [];
        for (const kind of windows) {
            for (const initial of [["stays-on-top", Qt.Window | Qt.WindowStaysOnTopHint],
                                   ["already-frameless", Qt.Window | Qt.FramelessWindowHint]]) {
                for (const leave of [["dark", dark], ["no-theme", noTheme]])
                    rows.push({ tag: kind.tag + "/" + initial[0] + "/" + leave[0], kind: kind, initial: initial[1], leave: leave[1] });
            }
        }
        return rows;
    }
    // (Moved from tst_ui_style_repair1.qml, review1 R2, now on the real
    // windows.) Only a hint Ditto added is taken away: light → dark or no
    // theme (an undo) → light → off again gives Qt's title bar back each
    // time with exactly the flags the window had; a hint set elsewhere stays.
    function test_flags_set_elsewhere_are_kept(row) {
        const tokens = tokensWith(row.initial & Qt.FramelessWindowHint ? light("j2") : row.leave);
        const win = open(row.kind, tokens, row.initial);
        compare(win.backingWindow.flags, row.initial);
        for (const style of ["j1", "j3"]) {
            tokens.appearance = light(style);
            wait(0);
            expectSafe(win, style);
            verify(frameless(win), style + ": one title, Qt draws none");
            compare(win.backingWindow.flags & ~Qt.FramelessWindowHint, row.initial & ~Qt.FramelessWindowHint, "other flags kept");
            tokens.appearance = row.leave;
            wait(0);
            expectSafe(win, "off after " + style);
            compare(win.backingWindow.flags, row.initial, "no style: back to exactly the flags it had");
        }
    }

    function test_header_destroyed_data() {
        return windows.map(kind => ({ tag: kind.tag, kind: kind }));
    }
    // The header goes with its window (closing it) and with the style; the
    // flags do not change on the shown window either way.
    function test_header_destroyed(row) {
        const tokens = tokensWith(light("j2"));
        const win = open(row.kind, tokens);
        const writes = win.flagWrites;
        const backing = win.backingWindow;
        created.splice(created.indexOf(win), 1);
        win.destroy();
        wait(0);
        compare(JSON.stringify(writes.filter(write => write.shown)), "[]", "closing a styled window");
        verify(!backing || !backing.visible);
    }
}
