import QtQuick
import QtTest
import Quickshell
import DittoStub
import "../../../../shell/jelly" as Jelly

// The real dock_pill provider (shell/providers/dock_pill), staged by
// ../stage-providers.mjs with only its layer-shell lines removed, against a
// fixture client. Applications, windows and icons here are test data.
TestCase {
    id: testCase
    name: "DockPillIcons"
    width: 1280
    height: 800
    visible: true
    when: windowShown

    Item {
        id: desktop
        width: 1280
        height: 800
    }

    Jelly.Tokens {
        id: tokens
        appearance: ({ theme: "soft-jelly-light", tokens: {}, locale: "zh-TW" })
    }

    QtObject {
        id: client
        property var windows: []
        property var calls: []
        property var apps: []
        function t(text) { return text; }
        function errorText(error) { return "failed"; }
        function focusWindow(id) { calls = calls.concat(["focus " + id]); }
        function launchApp(id, ok, fail) { calls = calls.concat(["launch " + id]); }
        function propose(ops, options, ok, fail) { calls = calls.concat(["propose " + JSON.stringify(ops[0].after.pinned)]); }
        function capability(method, args, ok, fail) {
            if (method === "desktop.launcher.list_apps") ok({ apps: apps });
            else fail({ name: "unexpected", message: method });
        }
    }

    readonly property string iconFile: Qt.resolvedUrl("../fixtures/test-icon.svg").toString().replace("file://", "")

    property var created: []

    function cleanup() {
        for (const object of created) {
            object.release();
            object.destroy();
        }
        created = [];
        wait(0);
    }

    function init() {
        StubDesktop.layer = desktop;
        Quickshell.iconMap = { "fixture-icon": Qt.resolvedUrl("../fixtures/test-icon.svg") };
        client.calls = [];
        client.apps = [
            { app_id: "org.example.Files", name: "Files", icon: "fixture-icon" },
            { app_id: "org.example.Editor", name: "Editor", icon: "" },
            { app_id: "org.example.Absolute", name: "Absolute", icon: testCase.iconFile },
            { app_id: "org.example.Missing", name: "Missing icon", icon: "no-such-icon" }
        ];
        client.windows = [
            { id: "w1", app_id: "files", title: "fixture", focused: true },
            { id: "w2", app_id: "org.example.Editor", title: "fixture", focused: false },
            { id: "w3", app_id: "unpinned.app", title: "fixture", focused: false }
        ];
    }

    function dock(config) {
        const component = Qt.createComponent(Qt.resolvedUrl("../.staged/providers/DockPill.qml"));
        verify(component.status === Component.Ready, component.errorString());
        // Created the way shell/core/SlotHost.qml does (incubateObject keeps
        // the config's arrays as arrays; createObject would not).
        const incubator = component.incubateObject(testCase, {
            client: client, tokens: tokens, entryId: "dock-entry", slotName: "ui.dock", shown: false,
            config: config || { position: "bottom",
                pinned: ["org.example.Files", "org.example.Editor", "org.example.Absolute", "org.example.Missing", "org.example.NotInstalled"] }
        });
        incubator.forceCompletion();
        const provider = incubator.object;
        created.push(provider);
        provider.shown = true;
        tryCompare(provider, "appsLoaded", true);
        return provider;
    }

    function tile(appId) {
        return findChild(desktop, "dockTile_" + appId);
    }

    function test_entries_are_pinned_known_apps_then_running_windows() {
        const provider = dock();
        compare(provider.entries.map(entry => entry.appId),
                ["org.example.Files", "org.example.Editor", "org.example.Absolute", "org.example.Missing", "unpinned.app"]);
        verify(provider.healthy());
    }

    function test_icons_and_readable_fallback() {
        dock();
        tryCompare(findChild(tile("org.example.Files"), "dockIcon"), "status", Image.Ready);
        verify(findChild(tile("org.example.Files"), "dockIcon").visible);
        verify(!findChild(tile("org.example.Files"), "dockIconFallback").visible);
        tryCompare(findChild(tile("org.example.Absolute"), "dockIcon"), "status", Image.Ready);
        for (const appId of ["org.example.Editor", "org.example.Missing", "unpinned.app"]) {
            const fallback = findChild(tile(appId), "dockIconFallback");
            verify(fallback.visible, appId + " shows the lettered tile");
            verify(!findChild(tile(appId), "dockIcon").visible);
        }
        compare(findChild(tile("org.example.Editor"), "dockIconFallback").children[0].text, "Ed");
    }

    function test_focused_and_running_are_told_apart() {
        dock();
        const focused = findChild(tile("org.example.Files"), "dockIndicator");
        const running = findChild(tile("org.example.Editor"), "dockIndicator");
        const idle = findChild(tile("org.example.Absolute"), "dockIndicator");
        verify(focused.visible && running.visible && !idle.visible);
        compare(focused.width, 16);
        compare(running.width, 5);
        compare(String(focused.color), String(tokens.focus));
        compare(String(running.color), String(tokens.foregroundMuted));
    }

    function test_accessible_names_say_the_state() {
        dock();
        compare(tile("org.example.Files").Accessible.name, "Files（使用中）（已釘選）");
        compare(tile("org.example.Editor").Accessible.name, "Editor（執行中）（已釘選）");
        compare(tile("org.example.Absolute").Accessible.name, "Absolute（已釘選）");
        compare(tile("unpinned.app").Accessible.name, "unpinned.app（執行中）");
        compare(tile("org.example.Files").Accessible.role, Accessible.Button);
    }

    function test_keyboard_matches_pointer() {
        dock();
        const files = tile("org.example.Files");
        files.forceActiveFocus();
        verify(files.activeFocus);
        keyClick(Qt.Key_Return);
        keyClick(Qt.Key_Tab);
        verify(tile("org.example.Editor").activeFocus);
        keyClick(Qt.Key_Tab);
        verify(tile("org.example.Absolute").activeFocus);
        keyClick(Qt.Key_Space);
        keyClick(Qt.Key_Menu);
        compare(client.calls, ["focus w1", "launch org.example.Absolute",
            "propose " + JSON.stringify(["org.example.Files", "org.example.Editor", "org.example.Missing", "org.example.NotInstalled"])]);
        client.calls = [];
        mouseClick(tile("org.example.Absolute"));
        mouseClick(tile("org.example.Files"));
        compare(client.calls, ["launch org.example.Absolute", "focus w1"]);
    }

    function test_floating_capsule_and_input_region() {
        const provider = dock();
        const capsule = findChild(desktop, "dockCapsule");
        tryVerify(() => capsule.width > capsule.height * 2, 2000, "a horizontal capsule");
        const window = capsule.parent;
        const centre = window.x + capsule.x + capsule.width / 2;
        verify(Math.abs(centre - 640) <= 1, "centred: " + centre);
        compare(window.y + window.height, 800);
        compare(window.height - capsule.y - capsule.height, provider.edgeGap);
        compare(provider.reservedEdge, "bottom");
        // The input region is the capsule, not the window's transparent margin.
        const panel = provider.data.find(item => item.mask !== undefined && item.mask !== null);
        compare(panel.mask.item, capsule);
        compare(panel.exclusiveZone, provider.thickness);
        provider.release();
        verify(!window.visible);
        compare(panel.exclusiveZone, 0);
    }

    function test_left_position() {
        const provider = dock({ position: "left", pinned: ["org.example.Files"] });
        const capsule = findChild(desktop, "dockCapsule");
        tryVerify(() => capsule.height > capsule.width * 2, 2000, "a vertical capsule");
        compare(capsule.parent.x, 0);
        compare(provider.reservedEdge, "left");
    }
}
