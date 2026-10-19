import QtQuick
import QtTest
import DittoStub
import Quickshell
import "../../../../shell/jelly" as Jelly

// #116 Dock (dock_pill) with a candidate style: an application without an
// icon gets a themed squircle with its initial, and running / in use share
// one indicator shape (in use: longer, in the selection colour; no plate).
// Without a style the light recipe's lettered tile and bar/dot stay
// (tst_dock.qml, tst_ui_style_off.qml). Staged provider, fixture data.
TestCase {
    id: testCase
    name: "UiStyleDock"
    width: 1280
    height: 800
    visible: true
    when: windowShown

    Item { id: desktop; width: 1280; height: 800 }
    Jelly.Tokens { id: tokens; appearance: ({ theme: "soft-jelly-light", tokens: {} }) }
    QtObject {
        id: client
        property var windows: [
            { id: "w1", app_id: "org.example.Files", title: "fixture", focused: true },
            { id: "w2", app_id: "org.example.Orbit", title: "fixture", focused: false }
        ]
        property var apps: [
            { app_id: "org.example.Files", name: "files", icon: "" },
            { app_id: "org.example.Orbit", name: "orbit", icon: "" },
            { app_id: "org.example.Icon", name: "Icon", icon: "fixture-icon" }
        ]
        function t(text) { return text; }
        function errorText(error) { return "failed"; }
        function focusWindow(id) {}
        function launchApp(id, ok, fail) {}
        function propose(ops, options, ok, fail) {}
        function capability(method, args, ok, fail) {
            if (method === "desktop.launcher.list_apps") ok({ apps: apps });
            else fail({ name: "unexpected", message: method });
        }
    }
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
        Quickshell.iconMap = ({ "fixture-icon": Qt.resolvedUrl("../fixtures/test-icon.svg") });
    }
    function cleanup() {
        if (dock) { dock.release(); dock.destroy(); dock = null; }
        wait(20);
    }
    function mount(style) {
        tokens.uiStyle = style;
        const component = Qt.createComponent(Qt.resolvedUrl("../.staged/providers/DockPill.qml"));
        verify(component.status === Component.Ready, component.errorString());
        const incubator = component.incubateObject(testCase, { client: client, tokens: tokens, entryId: "dock", slotName: "ui.dock", shown: false,
            config: { position: "bottom", pinned: ["org.example.Files", "org.example.Orbit", "org.example.Icon"] } });
        incubator.forceCompletion();
        dock = incubator.object;
        dock.shown = true;
        tryCompare(dock, "appsLoaded", true);
        tryVerify(() => find(desktop, "dockTile_org.example.Icon") !== null);
        const icon = find(find(desktop, "dockTile_org.example.Icon"), "dockIcon");
        tryVerify(() => icon.status !== Image.Loading);
        tryCompare(dock, "reveal", 1);
        waitForRendering(desktop);
    }

    function test_candidate_fallback_and_indicator_data() {
        return ["j1", "j2", "j3"].map(style => ({ tag: style, style: style }));
    }
    function test_candidate_fallback_and_indicator(row) {
        mount(row.style);
        verify(dock.jelly);
        const files = find(desktop, "dockTile_org.example.Files");
        const orbit = find(desktop, "dockTile_org.example.Orbit");
        const icon = find(desktop, "dockTile_org.example.Icon");
        for (const tile of [files, orbit]) {
            verify(find(tile, "dockIconSquircle").visible, "missing icon: themed squircle");
            verify(!find(tile, "dockIconFallback").visible, "not the plain lettered tile");
        }
        verify(!find(icon, "dockIconSquircle").visible && find(icon, "dockIcon").visible, "a real icon stays");
        const initial = find(files, "dockIconSquircle").children.find(child => child.text !== undefined);
        compare(initial.text, "F", "one capital initial");
        const inUse = find(files, "dockIndicator"), running = find(orbit, "dockIndicator");
        verify(inUse.visible && running.visible);
        compare(inUse.radius, running.radius, "one indicator shape");
        compare(inUse.height, running.height);
        verify(inUse.width > running.width, "in use is longer, not a different mark");
        verify(Qt.colorEqual(inUse.color, tokens.uiSelectDot));
        verify(!find(icon, "dockIndicator").visible, "not running: no indicator");
        compare(files.Accessible.name, "files（使用中）（已釘選）", "the state is in words too");
    }

    function test_no_style_keeps_the_light_recipe() {
        mount("");
        verify(!dock.jelly && dock.soft);
        const files = find(desktop, "dockTile_org.example.Files");
        verify(find(files, "dockIconFallback").visible);
        verify(!find(files, "dockIconSquircle").visible);
        compare(find(files, "dockIndicator").width, 16);
    }
}
