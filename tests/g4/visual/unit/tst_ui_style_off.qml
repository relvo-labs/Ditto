import QtQuick
import QtTest
import DittoStub
import Quickshell
import "../fixtures" as Fixtures

// #116: the application styles (Profile token `ui_style`, J1 by default)
// belong to the light recipe. With the dark recipe (`soft-jelly`, also when
// its Profile sets `ui_style`) and with no theme, the Shell's application
// surfaces must render exactly as at the base (87a2462, PR #115). ../stage-ui116.mjs exports the
// base files to .staged/ui116/base and copies the working tree to
// .staged/ui116/current (layer-shell lines removed in both, recorded in its
// staging.json). Each scene is drawn from each tree with that tree's own
// Tokens and the same fixture data, and the pixels must be equal. Same method
// as tst_legacy.qml. Development evidence: offscreen software renderer.
TestCase {
    id: testCase
    name: "UiStyleOffMatchesBase"
    width: 1280
    height: 800
    visible: true
    when: windowShown

    Rectangle { id: desktop; width: 1280; height: 800; color: "#808080" }

    Fixtures.AppFixtureClient { id: client }
    Fixtures.ConversationFixture { id: offConversation; scene: "off" }
    Fixtures.ConversationFixture { id: activeConversation; scene: "active" }

    readonly property url staged: Qt.resolvedUrl("../.staged/ui116/")
    readonly property var appearances: [
        { tag: "dark", value: { theme: "soft-jelly", tokens: {}, locale: "zh-TW" } },
        { tag: "dark-ui-style-j3", value: { theme: "soft-jelly", tokens: { ui_style: "j3" }, locale: "zh-TW" } },
        { tag: "dark-reduced-transparency", value: { theme: "soft-jelly", tokens: {}, reduced_transparency: true } },
        { tag: "dark-low-power", value: { theme: "soft-jelly", tokens: {}, low_power_style: true } },
        { tag: "no-theme", value: null }
    ]
    property var created: []

    function init() {
        StubDesktop.layer = desktop;
        Quickshell.environment = ({});
    }
    function cleanup() {
        for (const object of created) {
            if (object.release) object.release();
            object.destroy();
        }
        created = [];
        wait(0);
    }

    function make(tree, path, properties) {
        const component = Qt.createComponent(staged + tree + "/" + path);
        verify(component.status === Component.Ready, tree + " " + path + ": " + component.errorString());
        const object = component.createObject(desktop, properties || {});
        verify(object !== null, tree + " " + path);
        created.push(object);
        return object;
    }
    function tokensOf(tree, appearance) {
        return make(tree, "shell/jelly/Tokens.qml", { appearance: appearance });
    }
    function snapshot() {
        // Finite transitions (toggle knob 120 ms after the fixture data
        // lands, compact presentation 180 ms) settle before the grab.
        // The text cursor blinks: take keyboard focus away (same in both trees).
        desktop.forceActiveFocus();
        waitForRendering(desktop, 300);
        wait(450);
        waitForRendering(desktop, 300);
        return grabImage(desktop);
    }
    function clear() {
        cleanup();
    }
    function same(label, render) {
        const before = render("base");
        clear();
        const after = render("current");
        clear();
        if (!after.equals(before)) {
            const name = label.replace(/[^a-z0-9-]+/gi, "_");
            before.save(String(staged).replace("file://", "") + "diff-" + name + "-base.png");
            after.save(String(staged).replace("file://", "") + "diff-" + name + "-current.png");
        }
        verify(after.equals(before), label + ": pixels differ from the base");
    }

    // ---- shared controls ----------------------------------------------------------------
    function test_controls_match_base_data() {
        return appearances;
    }
    function test_controls_match_base(row) {
        same("controls " + row.tag, tree => {
            const tokens = tokensOf(tree, row.value);
            const ui = staged + tree + "/shell/ui";
            const scene = Qt.createQmlObject(`
                import QtQuick
                import "${ui}" as Ui
                Column {
                    id: scene
                    property var tokens
                    x: 20; y: 20; width: 900; spacing: 10
                    Row { spacing: 8
                        Ui.Button { tokens: scene.tokens; kind: "primary"; text: "使用這個組合" }
                        Ui.Button { tokens: scene.tokens; text: "試看" }
                        Ui.Button { tokens: scene.tokens; kind: "subtle"; text: "取消" }
                        Ui.Button { tokens: scene.tokens; kind: "danger"; text: "刪除" }
                        Ui.Button { tokens: scene.tokens; kind: "primary"; text: "送出"; enabled: false }
                        Ui.Button { id: focused; tokens: scene.tokens; text: "焦點" }
                    }
                    Row { spacing: 8
                        Ui.Badge { tokens: scene.tokens; tone: "good"; text: "使用中" }
                        Ui.Badge { tokens: scene.tokens; tone: "warn"; text: "等待保留" }
                        Ui.Badge { tokens: scene.tokens; tone: "bad"; text: "失敗" }
                        Ui.Badge { tokens: scene.tokens; tone: "info"; text: "目前版本" }
                        Ui.Badge { tokens: scene.tokens; text: "已安裝，未啟用" }
                    }
                    Ui.Choice { tokens: scene.tokens; options: [{ value: "a", label: "膠囊式 Dock" }, { value: "b", label: "視窗列 Dock" }]; value: "a" }
                    Ui.Choice { tokens: scene.tokens; options: [{ value: "a", label: "頂部面板" }]; value: "a"; enabled: false }
                    Ui.Toggle { tokens: scene.tokens; text: "降低透明度"; labelOn: "開"; labelOff: "關"; checked: true }
                    Ui.Toggle { tokens: scene.tokens; text: "低效能樣式"; labelOn: "開"; labelOff: "關" }
                    Ui.TextField { tokens: scene.tokens; placeholder: "新組合的名稱，這個提示比欄位還要長很多很多很多" }
                    Ui.TextArea { tokens: scene.tokens; width: 400; height: 60; text: "{ \\"profile\\": 1 }" }
                    Ui.Section { tokens: scene.tokens; title: "已存的組合"; note: "選擇一個元件後可以先「試看」或直接「套用」。"
                        Text { text: "內容" } }
                    Ui.Diagnostics { tokens: scene.tokens; title: "診斷"; text: "fixture"; width: 300 }
                    Component.onCompleted: focused.forceActiveFocus()
                }`, desktop, "controls-" + tree);
            scene.tokens = tokens;
            created.push(scene);
            return snapshot();
        });
    }

    // ---- centers ---------------------------------------------------------------------------
    function test_centers_match_base_data() {
        const rows = [];
        for (const appearance of appearances)
            for (const page of ["composition", "plugins", "history", "personalization", "ai"])
                rows.push({ tag: appearance.tag + "/" + page, appearance: appearance.value, page: page });
        return rows;
    }
    function test_centers_match_base(row) {
        same("centers " + row.tag, tree => {
            const tokens = tokensOf(tree, row.appearance);
            make(tree, "shell/centers/Centers.qml", { client: client, tokens: tokens, conversation: offConversation, page: row.page });
            return snapshot();
        });
    }

    // ---- chat and approval -------------------------------------------------------------
    function test_chat_match_base_data() {
        const rows = [];
        for (const appearance of appearances)
            for (const scene of ["window-off", "window-active", "panel-off", "panel-entry-active", "approval"])
                rows.push({ tag: appearance.tag + "/" + scene, appearance: appearance.value, scene: scene });
        return rows;
    }
    function test_chat_match_base(row) {
        same("chat " + row.tag, tree => {
            const tokens = tokensOf(tree, row.appearance);
            const conversation = row.scene.indexOf("active") >= 0 ? activeConversation : offConversation;
            if (row.scene.indexOf("window") === 0) {
                make(tree, "shell/chat/ChatWindow.qml", { client: client, tokens: tokens, conversation: conversation, assistantPresentation: true });
            } else if (row.scene.indexOf("panel") === 0) {
                make(tree, "shell/chat/ChatPanel.qml", { client: client, tokens: tokens, conversation: conversation, screen: { width: 1280, height: 800 }, animations: false,
                    entryRect: row.scene === "panel-entry-active" ? Qt.rect(1065, 710, 195, 56) : null });
            } else {
                make(tree, "shell/chat/ApprovalWindow.qml", { client: client, tokens: tokens,
                    approval: { request_id: "req-fixture", request: { capability_id: "desktop.windows.list", resource: "desktop.windows.read", purpose: "（fixture）查看視窗" } } });
            }
            return snapshot();
        });
    }

    // ---- Dock ----------------------------------------------------------------------------
    function test_dock_matches_base_data() {
        return appearances;
    }
    function test_dock_matches_base(row) {
        client.apps = [
            { app_id: "org.example.Files", name: "Files", icon: "" },
            { app_id: "org.example.Orbit", name: "orbit", icon: "" },
            { app_id: "org.example.Editor", name: "Editor", icon: "missing-icon-name" }
        ];
        client.windows = [
            { id: "w1", app_id: "org.example.Files", title: "fixture", focused: true },
            { id: "w2", app_id: "org.example.Orbit", title: "fixture", focused: false }
        ];
        same("dock " + row.tag, tree => {
            const tokens = tokensOf(tree, row.appearance);
            const dock = make(tree, "shell/providers/dock_pill/qml/DockPill.qml", {
                client: client, tokens: tokens, entryId: "dock", slotName: "ui.dock", shown: false,
                config: { position: "bottom", pinned: ["org.example.Files", "org.example.Orbit", "org.example.Editor"] } });
            dock.shown = true;
            tryCompare(dock, "appsLoaded", true);
            wait(400); // reveal (180 ms) settles
            return snapshot();
        });
        client.windows = [];
        client.apps = [];
    }
}
