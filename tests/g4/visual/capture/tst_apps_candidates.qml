import QtQuick
import QtTest
import Quickshell
import DittoStub
import "../../../../shell/jelly" as Jelly
import "../fixtures" as Fixtures
import "../.staged/capture-data.js" as Data

// #116 style screens, 1280×800 at scale 1, offscreen. For each selectable
// style (Profile `appearance.tokens.ui_style`; J1 jelly glass is the
// default, owner 2026-10-20) J1/J2/J3: composition center (normal, reduced
// transparency, low power, and with the ⋯ menu open), personalization (with
// the style choice), AI settings, chat with AI off (window and the compact
// panel beside the character), chat in progress with a pending approval, and
// the Dock with applications that have no icon. The earlier light
// presentation is no longer a choice and is not captured.
//
// Everything drawn is the real Shell QML: Backdrop with the light recipe's
// wallpaper, the staged PanelTop and DockPill providers, Centers, ChatWindow,
// ApprovalWindow. Data are labelled fixtures (fixtures/AppFixtureClient.qml,
// ConversationFixture.qml); there is no Core, model or compositor, so window
// decorations drawn by Qt/Wayfire on a real session (the current
// presentation's title bars) and window shadows do not appear. The clock is
// the real time of the run. Development evidence only.
TestCase {
    id: testCase
    name: "CaptureAppCandidates"
    width: 1280
    height: 800
    visible: true
    when: windowShown

    readonly property string outDir: Qt.resolvedUrl("../.staged/out/candidates/").toString().replace("file://", "")

    Item {
        id: screen
        width: 1280
        height: 800

        Jelly.Backdrop {
            anchors.fill: parent
            tokens: sceneTokens
            wallpaperSource: sceneTokens.wallpaper
        }
        Item { id: layer; anchors.fill: parent }
    }

    Jelly.Tokens { id: sceneTokens }
    Fixtures.AppFixtureClient { id: client }
    Fixtures.ConversationFixture { id: offConversation; scene: "off" }
    Fixtures.ConversationFixture { id: activeConversation; scene: "active" }

    property var mounted: []
    readonly property var styles: ["j1", "j2", "j3"]
    /// Work area of this 1280×800 scene: the top bar (36) and the pill
    /// Dock's reservation (82) as on the VM; Wayfire centres new windows in it.
    function centredY(height) {
        return Math.round(36 + (800 - 36 - 82 - height) / 2);
    }

    function findChild(root, name) {
        if (!root) return null;
        if (root.objectName === name) return root;
        for (const child of root.children) {
            const found = findChild(child, name);
            if (found) return found;
        }
        return null;
    }
    function findAccessible(root, name) {
        if (!root) return null;
        if (root.Accessible && root.Accessible.name === name && root.activeFocusOnTab) return root;
        for (const child of root.children) {
            const found = findAccessible(child, name);
            if (found) return found;
        }
        return null;
    }
    function rect(item) {
        const p = item.mapToItem(screen, 0, 0);
        return { x: Math.round(p.x), y: Math.round(p.y), width: Math.round(item.width), height: Math.round(item.height) };
    }
    function mount(path, properties, staged) {
        // staged: true = a staged provider; "chat" = the staged ui116 copy of
        // shell/chat (ChatPanel is a layer-shell window, see stage-ui116.mjs).
        const url = staged === "chat" ? "../.staged/ui116/current/shell/chat/" + path
            : staged ? "../.staged/providers/" + path : "../../../../shell/" + path;
        const component = Qt.createComponent(Qt.resolvedUrl(url));
        verify(component.status === Component.Ready, component.errorString());
        const incubator = component.incubateObject(layer, properties);
        incubator.forceCompletion();
        verify(incubator.object !== null, path);
        mounted.push(incubator.object);
        return incubator.object;
    }
    function unmountAll() {
        for (const object of mounted) {
            if (object.release) object.release();
            object.destroy();
        }
        mounted = [];
        wait(50);
    }

    function initTestCase() {
        StubDesktop.layer = layer;
        Quickshell.iconMap = Data.iconMap;
        // Real installed applications (prepare.py) plus two without an
        // icon (labelled fixtures): the Dock's fallback is part of the review.
        client.apps = Data.apps.slice(0, 4).concat([
            { app_id: "org.codeberg.dnkl.foot", name: "foot", icon: "fixture-missing-foot" },
            { app_id: "org.example.Orbit", name: "orbit", icon: "" }
        ]);
    }

    function shell(style, mode) {
        // The style as a Profile holds it: J1 is also what no value gives.
        const tokens = { accent: "#b9a4ff" };
        if (style !== "j1") tokens.ui_style = style;
        sceneTokens.appearance = {
            theme: "soft-jelly-light", tokens: tokens, locale: "zh-TW",
            reduced_transparency: mode === "reduced-transparency", low_power_style: mode === "low-power"
        };
        compare(sceneTokens.uiStyle, style);
        const pinned = client.apps.map(app => app.app_id);
        const dock = mount("DockPill.qml", { client: client, tokens: sceneTokens, config: { position: "bottom", pinned: pinned },
                                             entryId: "dock", slotName: "ui.dock", shown: false }, true);
        const panel = mount("PanelTop.qml", { client: client, tokens: sceneTokens, config: {}, entryId: "panel", slotName: "ui.panel_top", shown: false }, true);
        dock.shown = true;
        panel.shown = true;
        tryCompare(dock, "appsLoaded", true);
        tryVerify(() => dock.entries.every(entry => {
            const icon = findChild(findChild(layer, "dockTile_" + entry.appId), "dockIcon");
            return icon && icon.status !== Image.Loading;
        }), 5000, "dock icons settled");
        return dock;
    }

    function settle(dock) {
        tryCompare(dock, "reveal", 1);
        tryVerify(() => dock.entries.every(entry => !findChild(layer, "dockTile_" + entry.appId).motionRunning));
        layer.forceActiveFocus();
        waitForRendering(screen, 500);
        wait(450);
        waitForRendering(screen, 500);
    }

    function save(style, scene, mode, extra) {
        const name = style + "-" + scene + (mode && mode !== "normal" ? "-" + mode : "");
        const path = outDir + name + ".png";
        grabImage(screen).save(path);
        console.log("CANDIDATE_CAPTURE " + JSON.stringify(Object.assign({
            style: style, scene: scene, mode: mode || "normal", file: path,
            viewport: { width: 1280, height: 800, scale: 1 },
            renderer: screen.GraphicsInfo.api === GraphicsInfo.Software ? "software" : "hardware",
            ui_style: sceneTokens.uiStyle, fixture: true
        }, extra || {})));
    }

    function centers(style, page, mode, openMenu) {
        const dock = shell(style, mode);
        client.windows = [];
        const window = mount("centers/Centers.qml", { client: client, tokens: sceneTokens, conversation: offConversation, page: page,
                                                       screen: { width: 1280, height: 800 } });
        // Where Wayfire's `place` would centre a window of its own height in
        // the work area; the stub has no real placement.
        window.x = Math.round((1280 - window.width) / 2);
        window.y = centredY(window.height);
        if (openMenu) tryVerify(() => findChild(window, "profileCard") !== null, 3000);
        settle(dock);
        let menu = null;
        if (openMenu) {
            // The ⋯ of the second composition (開發).
            const menus = [];
            const walk = item => { for (const child of item.children) { if (child.objectName === "overflowButton") menus.push(child); walk(child); } };
            walk(window);
            verify(menus.length >= 2, "overflow menus");
            // Scroll the page so the saved compositions are in view.
            let page = menus[1];
            while (page && page.contentY === undefined) page = page.parent;
            const card = findChild(window, "profileCard");
            page.contentY = Math.max(0, card.mapToItem(page.contentItem, 0, 0).y - 60);
            waitForRendering(screen, 500);
            mouseClick(menus[1]);
            menu = menus[1].parent;
            verify(menu.open);
            waitForRendering(screen, 500);
        }
        save(style, openMenu ? "composition-menu" : page, mode, { window: rect(window) });
        if (menu) menu.closeMenu(false);
        unmountAll();
    }

    function chat(style, scene) {
        const dock = shell(style, "normal");
        const conversation = scene === "chat-active" ? activeConversation : offConversation;
        client.windows = scene === "chat-active" ? [{ id: "w-chat", app_id: "ditto.chat", title: "Ditto 對話", focused: true }] : [];
        const window = mount("chat/ChatWindow.qml", { client: client, tokens: sceneTokens, conversation: conversation, assistantPresentation: true,
                                                       screen: { width: 1280, height: 800 } });
        window.x = scene === "chat-active" ? 220 : Math.round((1280 - window.width) / 2);
        window.y = centredY(window.height);
        let approval = null;
        if (scene === "chat-active") {
            approval = mount("chat/ApprovalWindow.qml", { client: client, tokens: sceneTokens,
                approval: { request_id: "req-fixture", request: { capability_id: "desktop.windows.list",
                    resource: "desktop.windows.read", purpose: "（fixture）查看視窗以移動 Dock" } } });
            approval.x = 700;
            approval.y = 250;
        }
        settle(dock);
        if (approval) {
            // Refusing is the keyboard default: show where focus starts.
            const reject = findAccessible(approval, "拒絕");
            verify(reject !== null, "reject button");
            reject.forceActiveFocus();
            waitForRendering(screen, 500);
        }
        save(style, scene, "normal", { window: rect(window), approval: approval ? rect(approval) : null });
        unmountAll();
        client.windows = [];
    }

    /// The compact chat beside the character (the assistant's corner entry,
    /// bottom right), AI off: the VM defect scene of 2026-10-20.
    function chatPanel(style) {
        const dock = shell(style, "normal");
        client.windows = [];
        const panel = mount("ChatPanel.qml", { client: client, tokens: sceneTokens, conversation: offConversation,
            screen: { width: 1280, height: 800 }, animations: false, entryRect: Qt.rect(1196, 730, 56, 56) }, "chat");
        settle(dock);
        save(style, "chat-panel-off", "normal", { panel: rect(findChild(layer, "chatPresentationFrame")) });
        unmountAll();
    }

    function dockScene(style) {
        client.windows = [
            { id: "w-foot", app_id: "org.codeberg.dnkl.foot", title: "foot", focused: true },
            { id: "w-orbit", app_id: "org.example.Orbit", title: "orbit", focused: false },
            { id: "w-files", app_id: Data.apps[0].app_id, title: "Files", focused: false }
        ];
        const dock = shell(style, "normal");
        settle(dock);
        const icons = dock.entries.map(entry => {
            const tile = findChild(layer, "dockTile_" + entry.appId);
            const icon = findChild(tile, "dockIcon");
            return { app_id: entry.appId, icon: icon.status === Image.Ready ? "ready" : "fallback", name: tile.Accessible.name };
        });
        save(style, "dock", "normal", { dock: rect(findChild(layer, "dockCapsule")), tiles: icons });
        unmountAll();
        client.windows = [];
    }

    function test_capture() {
        for (const style of styles) {
            centers(style, "composition", "normal", false);
            centers(style, "composition", "reduced-transparency", false);
            centers(style, "composition", "low-power", false);
            centers(style, "composition", "normal", true);
            centers(style, "personalization", "normal", false);
            centers(style, "ai", "normal", false);
            chat(style, "chat-off");
            chatPanel(style);
            chat(style, "chat-active");
            dockScene(style);
        }
    }
}
