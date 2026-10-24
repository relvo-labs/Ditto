import QtQuick
import QtTest
import Quickshell
import DittoStub
import "shell/jelly" as Jelly
import "capture-config.js" as Config

// Actual Centers + Personalization QML, offscreen window/layer stubs.
// Labelled synthetic protocol data. No VM, Core, global capture or save proof.
TestCase {
    id: testCase
    name: "ShortcutCaptures"
    width: 1280; height: 900; visible: true; when: windowShown
    ShortcutFixture { id: client }
    Jelly.Tokens { id: tokens; appearance: ({theme: "soft-jelly-light", tokens: {}}) }
    Item {
        id: scene
        width: 1280; height: 900
        Jelly.Backdrop { anchors.fill: parent; tokens: tokens; wallpaperSource: tokens.wallpaper }
        Rectangle {
            width: parent.width; height: 36; color: "#eee9fb"
            Text { anchors.centerIn: parent; text: "OFFSCREEN QML FIXTURE · #190 · " + Config.label + " · " + client.locale; color: "#302746"; font.pixelSize: 14 }
        }
        Item { id: layer; anchors.fill: parent }
    }
    function all(item, predicate) {
        let found = [];
        for (const child of item.children) { if (predicate(child)) found.push(child); found = found.concat(all(child, predicate)); }
        return found;
    }
    function create(path, props) {
        const c = Qt.createComponent(path); verify(c.status === Component.Ready, c.errorString());
        const object = c.createObject(layer, props); verify(object !== null); return object;
    }
    function test_capture() {
        StubDesktop.layer = layer;
        for (const locale of ["zh-TW", "en"]) for (const viewport of [1280, 900]) for (const state of ["list", "edit", "conflict", "reserved", "failure", "pending"]) {
            client.locale = locale;
            client.bindings = [{chord: "Super+Space", command: "launcher.toggle"}, {chord: "Super+A", command: "chat.toggle"}];
            client.headRevision = "rev-1"; client.pendingConfirmations = ({});
            scene.width = viewport;
            StubDesktop.screenWidth = viewport; StubDesktop.screenHeight = 900;
            const window = create("shell/centers/Centers.qml", {client: client, tokens: tokens, page: "personalization", screen: {height: 900}, implicitWidth: viewport === 1280 ? 1080 : 760});
            window.x = (viewport - window.width) / 2; window.y = 100;
            const page = window.currentPageItem;
            verify(page !== null);
            const settings = all(page, i => i.objectName === "shortcutSettings")[0];
            let field = null;
            if (settings) {
                if (state !== "list") {
                    const edit = all(settings, i => i.clicked !== undefined && i.Accessible.name === client.t("編輯 %1").arg(settings.title("launcher.toggle")))[0];
                    edit.clicked();
                    field = all(settings, i => i.objectName === "shortcutChord")[0];
                    field.text = state === "conflict" ? "Super+A" : state === "reserved" ? "Super+L" : "Super+K";
                    if (state === "failure" || state === "pending") settings.save();
                    if (state === "failure") client.failure({name: "preflight_rejected", message: "fixture write rejected"});
                    if (state === "pending") client.reply("pending");
                }
                page.contentY = settings.mapToItem(page.contentItem, 0, 0).y - 12;
            } else {
                const section = all(page, i => i.title === client.t("快捷鍵"))[0];
                page.contentY = section.mapToItem(page.contentItem, 0, 0).y - 12;
                if (state !== "list") {
                    field = all(page, i => i.placeholder === client.t("例如 Super+Space"))[0];
                    field.text = state === "conflict" ? "Super+A" : state === "reserved" ? "Super+L" : "Super+K";
                    all(page, i => i.chosenCommand !== undefined)[0].chosenCommand = "chat.toggle";
                    if (state === "failure" || state === "pending") all(page, i => i.clicked !== undefined && i.text === client.t("加入"))[0].clicked();
                    if (state === "failure") client.failure({name: "preflight_rejected", message: "fixture write rejected"});
                    if (state === "pending") client.reply("pending");
                }
            }
            const bar = create("shell/change/PreviewBar.qml", {client: client, tokens: tokens});
            layer.forceActiveFocus();
            waitForRendering(scene, 150); wait(180);
            // Let Centers focus-reveal settle, then use an explicit scroll for the review image.
            if (settings) {
                const editor = all(settings, i => i.objectName === "shortcutChord")[0];
                page.contentY = editor ? editor.mapToItem(page.contentItem, 0, 0).y - 350 : settings.mapToItem(page.contentItem, 0, 0).y - 12;
            } else {
                const section = all(page, i => i.title === client.t("快捷鍵"))[0];
                page.contentY = section.mapToItem(page.contentItem, 0, 0).y - 12;
            }
            waitForRendering(scene, 150);
            if (settings && state !== "list") {
                // A projection refresh may rebuild a row. Inspect the current editor.
                field = all(settings, i => i.objectName === "shortcutChord")[0];
                compare(field.text, settings.draftChord);
                verify(field.visible && field.height > 0);
            }
            const name = Config.label + "-" + locale + "-" + viewport + "-" + state + ".png";
            const path = Qt.resolvedUrl("captures/" + name).toString().replace("file://", "");
            grabImage(scene).save(path);
            console.log("SHORTCUT_CAPTURE " + JSON.stringify({file: path, candidate: Config.label, locale: locale, state: state, viewport: [viewport,900], fixture: true, renderer: "Qt Quick offscreen", pageWidth: page.width, contentY: page.contentY, draft: field ? field.text : null}));
            bar.destroy(); window.destroy(); wait(0);
        }
    }
}
