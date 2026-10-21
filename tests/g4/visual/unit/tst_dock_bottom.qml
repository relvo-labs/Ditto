import QtQuick
import QtTest
import Quickshell
import DittoStub
import "../../../../shell/jelly" as Jelly

// Dock A (shell/providers/dock_bottom), staged by ../stage-providers.mjs with
// only its layer-shell lines removed, against a fixture client. The window
// records reproduce what the owner saw on 2026-10-21 (raw app ids such as
// `org.gnome.Nautilus`, `org.quickshell`, a Chrome web app hash and a snap
// id); names and icons are test data, not this machine's index.
TestCase {
    id: testCase
    name: "DockBottomReadable"
    width: 1600
    height: 900
    visible: true
    when: windowShown

    Item { id: desktop; width: 1600; height: 900 }
    Jelly.Tokens { id: tokens; appearance: ({ theme: "soft-jelly-light", tokens: {}, locale: "zh-TW" }) }
    QtObject {
        id: client
        property bool online: true
        property string status: ""
        property var windows: []
        property var workspaces: []
        property var apps: []
        property var calls: []
        function t(text) { return text; }
        function focusWindow(id) { calls = calls.concat(["focus " + id]); }
        function closeWindow(id) { calls = calls.concat(["close " + id]); }
        property bool closeSupported: true
        function capabilityAvailable(id) { return id === "desktop.windows.close_request" && closeSupported; }
        function capability(method, args, ok, fail) {
            if (method === "desktop.launcher.list_apps") ok({ apps: apps });
            else fail({ name: "unexpected", message: method });
        }
    }
    readonly property string outDir: Qt.resolvedUrl("../.staged/out/").toString().replace("file://", "")
    property var dock: null

    function find(root, name) {
        if (!root) return null;
        if (root.objectName === name) return root;
        for (const child of root.children) {
            const found = find(child, name);
            if (found) return found;
        }
        return null;
    }
    function init() {
        StubDesktop.layer = desktop;
        StubDesktop.screenWidth = 1600; StubDesktop.screenHeight = 900;
        Quickshell.iconMap = ({ "fixture-icon": Qt.resolvedUrl("../fixtures/test-icon.svg") });
        client.calls = [];
        client.closeSupported = true;
        client.apps = [
            { app_id: "org.gnome.Nautilus", name: "檔案", icon: "fixture-icon" },
            { app_id: "org.codeberg.dnkl.foot", name: "Foot", icon: "" },
            { app_id: "code", name: "Visual Studio Code", icon: "fixture-icon" },
            { app_id: "google-chrome", name: "Google Chrome", icon: "fixture-icon" },
            { app_id: "telegram-desktop", name: "Telegram", icon: "fixture-icon" }
        ];
        client.workspaces = [{ id: "ws1", name: "1", active: true }, { id: "ws2", name: "2", active: false }];
        client.windows = [
            { id: "w1", app_id: "org.gnome.Nautilus", title: "下載", workspace_id: "ws1", focused: false, state: "normal" },
            { id: "w2", app_id: "org.quickshell", title: "Ditto 設定", workspace_id: "ws1", focused: false, state: "normal" },
            { id: "w3", app_id: "foot", title: "", workspace_id: "ws1", focused: false, state: "normal" },
            { id: "w4", app_id: "code", title: "DockBottom.qml - Ditto - Visual Studio Code", workspace_id: "ws2", focused: false, state: "normal" },
            { id: "w5", app_id: "google-chrome", title: "Manage access - Google Chrome", workspace_id: "ws1", focused: false, state: "minimized" },
            { id: "w6", app_id: "chrome-ophjlpahpchlmihnnnihgmmeilfjmjjc-Default", title: "", workspace_id: "ws1", focused: false, state: "normal" },
            { id: "w7", app_id: "telegram-desktop_telegram-desktop", title: "寶盛開單回報 – (13)", workspace_id: "ws1", focused: true, state: "normal" }
        ];
    }
    function cleanup() {
        if (dock) { dock.release(); dock.destroy(); dock = null; }
        wait(20);
    }
    function mount() {
        const component = Qt.createComponent(Qt.resolvedUrl("../.staged/providers/DockBottom.qml"));
        verify(component.status === Component.Ready, component.errorString());
        const incubator = component.incubateObject(testCase, { client: client, tokens: tokens, entryId: "dock",
            slotName: "ui.dock", screen: { name: "fixture", width: 1600, height: 900 }, shown: false, config: {} });
        incubator.forceCompletion();
        dock = incubator.object;
        dock.shown = true;
        tryCompare(dock, "appsLoaded", true);
        tryVerify(() => find(desktop, "dockWindow_w7") !== null);
        waitForRendering(desktop);
        return dock;
    }
    function label(id) { return find(find(desktop, "dockWindow_" + id), "dockWindowLabel"); }

    function test_labels_are_titles_not_app_ids() {
        mount();
        compare(label("w1").text, "下載");
        compare(label("w2").text, "Ditto 設定");
        compare(label("w3").text, "Foot", "empty title falls back to the application's name");
        compare(label("w4").text, "DockBottom.qml - Ditto", "trailing application name is dropped");
        compare(label("w5").text, "Manage access");
        compare(label("w6").text, "網頁應用程式", "an opaque web app id is not shown");
        compare(label("w7").text, "寶盛開單回報 – (13)");
        for (const id of ["w1", "w2", "w3", "w4", "w5", "w6", "w7"]) {
            const text = label(id).text;
            verify(text.indexOf("org.") < 0 && text.indexOf("chrome-") < 0 && text.indexOf("_") < 0, id + ": " + text);
        }
    }
    function test_application_matching() {
        mount();
        compare(dock.appName("foot"), "Foot");
        compare(dock.appName("telegram-desktop_telegram-desktop"), "Telegram");
        compare(dock.appName("org.quickshell"), "Ditto");
        compare(dock.appName("org.example.photo-viewer"), "Photo viewer");
        compare(dock.appName(""), "未命名應用程式");
    }
    function test_icons_and_fallback() {
        mount();
        for (const id of ["w1", "w4", "w5", "w7"]) {
            const tile = find(desktop, "dockWindow_" + id);
            tryCompare(find(tile, "dockWindowIconImage"), "status", Image.Ready);
            verify(!find(tile, "dockWindowIconFallback").visible, id);
        }
        for (const id of ["w2", "w3", "w6"]) {
            const tile = find(desktop, "dockWindow_" + id);
            verify(find(tile, "dockWindowIconFallback").visible, id + " has a lettered fallback");
        }
    }
    function test_states_are_not_colour_only() {
        mount();
        const focused = find(desktop, "dockWindow_w7"), other = find(desktop, "dockWindow_w1");
        verify(find(focused, "dockWindowIndicator").visible);
        verify(!find(other, "dockWindowIndicator").visible);
        compare(label("w7").font.weight, Font.DemiBold);
        compare(focused.Accessible.name, "Telegram：寶盛開單回報 – (13)（作用中）");
        compare(find(desktop, "dockWindow_w5").Accessible.name, "Google Chrome：Manage access（已最小化）");
        compare(label("w5").color, tokens.foregroundMuted);
        verify(find(find(desktop, "dockWindow_w5"), "dockWindowIcon").opacity < 1);
        const chip = find(find(desktop, "dockWindow_w4"), "dockWindowWorkspace");
        verify(chip.visible, "window on another workspace shows its workspace");
        compare(chip.children[0].text, "工作區 2");
        verify(!find(other, "dockWindowWorkspace").visible);
        compare(find(desktop, "dockWindow_w4").Accessible.name, "Visual Studio Code：DockBottom.qml - Ditto（工作區 2）");
    }
    function test_close_only_under_pointer_or_focus() {
        mount();
        const tile = find(desktop, "dockWindow_w1");
        const close = find(tile, "dockWindowClose");
        verify(!close.visible, "no close button at rest");
        mouseMove(tile, 30, tile.height / 2);
        tryVerify(() => close.visible);
        mouseClick(close, close.width / 2, close.height / 2);
        compare(client.calls, ["close w1"]);
        // Pointer moves on to the next window's tile.
        const next = find(desktop, "dockWindow_w2");
        mouseMove(next, 30, next.height / 2);
        tryVerify(() => !close.visible, 1000, "hidden again when the pointer leaves");
        tryVerify(() => find(next, "dockWindowClose").visible);
        tile.forceActiveFocus();
        verify(close.visible, "keyboard focus reveals it too");
        keyClick(Qt.Key_Return);
        compare(client.calls, ["close w1", "focus w1"]);
    }
    function test_close_hidden_without_capability() {
        client.closeSupported = false;
        mount();
        const tile = find(desktop, "dockWindow_w1");
        mouseMove(tile, 30, tile.height / 2);
        wait(20);
        verify(!find(tile, "dockWindowClose").visible, "an unsupported close is not offered");
        tile.forceActiveFocus();
        keyClick(Qt.Key_Delete);
        compare(client.calls, []);
    }
    function test_fits_the_screen() {
        mount();
        const bar = find(desktop, "dockBar");
        verify(bar.width <= 1600 - 2 * dock.edgeGap, "bar " + bar.width);
        const many = [];
        for (let i = 0; i < 16; ++i) many.push({ id: "m" + i, app_id: "code", title: "Window " + i, workspace_id: "ws1", focused: false, state: "normal" });
        client.windows = many;
        tryVerify(() => find(desktop, "dockWindow_m15") !== null);
        compare(find(desktop, "dockWindow_m0").width, dock.tileMinWidth);
    }
    function test_zz_capture() {
        mount();
        waitForRendering(desktop);
        const bar = find(desktop, "dockBar");
        const origin = bar.mapToItem(desktop, 0, 0);
        const image = grabImage(desktop);
        image.save(outDir + "dock-bottom-readable.png");
        console.log("DOCK_BOTTOM_BAR " + JSON.stringify({ x: origin.x, y: origin.y, width: bar.width, height: bar.height }));
    }
}
