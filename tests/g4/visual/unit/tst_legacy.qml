import QtQuick
import QtTest
import DittoStub
import "../../../../shell/jelly" as Jelly
import "../.staged/base" as Legacy

// Legacy presentation (#65 review I1): a Profile with the `soft-jelly` theme,
// or with no theme, preserves the G4 base geometry. #72 intentionally fixes
// accent foregrounds from black to the design value. The base
// files are exported by ../stage-providers.mjs into .staged/base/ and drawn
// next to the current ones with their own Tokens and the same fixture data;
// geometry and initials must match. Pixels must match when the current
// foreground is explicitly overridden to the old black. The light recipe
// (`soft-jelly-light`) must use the new presentation instead.
TestCase {
    id: testCase
    name: "LegacyPresentation"
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
        appearance: null
    }

    Legacy.Tokens { id: baseTokens; appearance: tokens.appearance }

    QtObject {
        id: client
        property var windows: []
        property var apps: []
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

    readonly property var legacyThemes: [null, { theme: "soft-jelly", tokens: {}, locale: "zh-TW" }]
    readonly property var lightTheme: ({ theme: "soft-jelly-light", tokens: {}, locale: "zh-TW" })
    property var created: []

    function init() {
        StubDesktop.layer = desktop;
        client.apps = [
            { app_id: "org.example.Files", name: "Files", icon: "fixture-icon" },
            { app_id: "org.example.Editor", name: "Editor", icon: "" },
            { app_id: "org.example.Viewer", name: "Viewer", icon: "" }
        ];
        // `viewer` (not pinned) matches org.example.Viewer only by its last
        // segment: the base showed the raw window id there ("vi"), and so
        // must the legacy path. `files` joins the pinned Files entry.
        client.windows = [
            { id: "w1", app_id: "files", title: "fixture", focused: true },
            { id: "w2", app_id: "org.example.Editor", title: "fixture", focused: false },
            { id: "w3", app_id: "viewer", title: "fixture", focused: false }
        ];
    }

    function cleanup() {
        for (const object of created) {
            if (object.release) object.release();
            object.destroy();
        }
        created = [];
        wait(0);
    }

    function mountDock(file, position) {
        const component = Qt.createComponent(Qt.resolvedUrl(file));
        verify(component.status === Component.Ready, component.errorString());
        const incubator = component.incubateObject(testCase, {
            client: client, tokens: file.indexOf("/base/") >= 0 ? baseTokens : tokens, entryId: "dock", slotName: "ui.dock", shown: false,
            config: { position: position, pinned: ["org.example.Files", "org.example.Editor"] }
        });
        incubator.forceCompletion();
        const provider = incubator.object;
        created.push(provider);
        provider.shown = true;
        tryCompare(provider, "appsLoaded", true);
        return provider;
    }

    function unmount(provider) {
        provider.release();
        provider.destroy();
        created = created.filter(item => item !== provider);
        wait(20);
    }

    /// The dock's buttons (the focusable tiles), in visual order.
    function tiles(root) {
        const found = [];
        const walk = item => {
            for (const child of item.children) {
                if (child.activeFocusOnTab && child.Accessible.role === Accessible.Button) found.push(child);
                walk(child);
            }
        };
        walk(root);
        return found;
    }

    /// The text drawn on each tile (visible Text descendants).
    function tileTexts(tile) {
        const texts = [];
        const walk = item => {
            for (const child of item.children) {
                if (child.visible && child.text !== undefined && child.font !== undefined) texts.push(child.text);
                if (child.visible) walk(child);
            }
        };
        walk(tile);
        return texts;
    }

    function visibleImages(root) {
        let count = 0;
        const walk = item => {
            for (const child of item.children) {
                if (child.visible && child.status !== undefined && child.sourceSize !== undefined && String(child.source) !== "") count += 1;
                if (child.visible) walk(child);
            }
        };
        walk(root);
        return count;
    }

    function dockState(provider) {
        const window = desktop.children.find(item => item.objectName === "stubPanelWindow" && item.visible);
        waitForRendering(desktop);
        return {
            thickness: provider.thickness,
            windowWidth: window.width,
            windowHeight: window.height,
            windowX: window.x,
            windowY: window.y,
            tiles: tiles(window).map(tile => ({ width: tile.width, height: tile.height, texts: tileTexts(tile) })),
            images: visibleImages(window),
            pixels: grabImage(desktop)
        };
    }

    function test_legacy_dock_matches_the_base() {
        for (const appearance of legacyThemes) {
            tokens.appearance = appearance;
            for (const position of ["bottom", "left"]) {
                const base = mountDock("../.staged/base/DockPill.qml", position);
                tryVerify(() => tiles(desktop).length === 3 && tiles(desktop)[0].width > 0);
                const before = dockState(base);
                unmount(base);
                const current = mountDock("../.staged/providers/DockPill.qml", position);
                tryVerify(() => tiles(desktop).length === 3 && tiles(desktop)[0].width > 0);
                const after = dockState(current);
                const label = (appearance ? appearance.theme : "no theme") + " " + position;
                compare(after.thickness, 60, label + ": reserved thickness");
                compare(after.thickness, before.thickness, label);
                compare(after.tiles.map(t => [t.width, t.height]), before.tiles.map(t => [t.width, t.height]), label + ": tile size");
                compare(after.tiles[0].width, 40, label);
                compare(after.tiles.map(t => t.texts), before.tiles.map(t => t.texts), label + ": initials");
                compare(after.tiles.map(t => t.texts), [["Fi"], ["Ed"], ["vi"]], label);
                compare(after.images, 0, label + ": no icon images");
                compare([after.windowX, after.windowY, after.windowWidth, after.windowHeight],
                        [before.windowX, before.windowY, before.windowWidth, before.windowHeight], label + ": window");
                compare(String(baseTokens.onAccent), "#000000", label + ": historical QML bug");
                compare(String(tokens.accentForeground), "#1a1626", label + ": fixed design value");
                verify(!after.pixels.equals(before.pixels), label + ": active initials intentionally change");
                tokens.appearance = Object.assign({}, appearance || {}, { tokens: { on_accent: "#000000" } });
                const oldForeground = dockState(current);
                verify(oldForeground.pixels.equals(before.pixels), label + ": only the accent foreground changed");
                tokens.appearance = appearance;
                // Theme-neutral fix: input only on the visible rounded capsule.
                const panel = current.data.find(item => item.mask !== undefined && item.mask !== null);
                verify(panel !== undefined, label + ": an input region");
                const capsule = panel.mask.item;
                verify(capsule !== null && capsule.visible, label + ": the region follows the visible capsule");
                verify(!panel.mask.contains(1, 1), label + ": corner outside the capsule");
                verify(panel.mask.contains(capsule.width / 2, capsule.height / 2), label + ": centre inside");
                unmount(current);
            }
        }
    }

    function test_light_dock_uses_the_new_presentation() {
        tokens.appearance = lightTheme;
        const provider = mountDock("../.staged/providers/DockPill.qml", "bottom");
        tryVerify(() => tiles(desktop).length === 3 && tiles(desktop)[0].width > 0);
        compare(provider.thickness, 84);
        compare(tiles(desktop)[0].width, 52);
    }

    Component {
        id: materialPair
        Item {
            id: pair
            required property var appearance
            property bool raised: true
            width: 600
            height: 260
            Jelly.Tokens { id: pairTokens; appearance: pair.appearance }
            Item {
                objectName: "baseSlot"
                x: 30; y: 40; width: 240; height: 160
            }
            Jelly.Material {
                objectName: "current"
                x: 330; y: 40; width: 240; height: 160
                tokens: pairTokens
                raised: pair.raised
            }
            property var pairTokensRef: pairTokens
        }
    }

    /// Visible rectangles of a material, with what decides their pixels.
    function structure(material) {
        const out = [];
        const walk = item => {
            for (const child of item.children) {
                if (!child.visible) continue;
                if (child.radius !== undefined && child.border !== undefined) {
                    out.push([child.x, child.y, child.width, child.height, child.radius, String(child.color),
                              String(child.border.color), child.border.width, child.opacity, child.gradient ? "gradient" : ""]);
                }
                walk(child);
            }
        };
        walk(material);
        return out;
    }

    function test_legacy_material_matches_the_base() {
        const baseComponent = Qt.createComponent(Qt.resolvedUrl("../.staged/base/Material.qml"));
        verify(baseComponent.status === Component.Ready, baseComponent.errorString());
        const modes = [{}, { reduced_transparency: true }, { low_power_style: true }];
        for (const theme of legacyThemes) {
            for (const mode of modes) {
                for (const raised of [true, false]) {
                    const appearance = Object.assign({}, theme || { tokens: {}, locale: "zh-TW" }, mode);
                    const pair = createTemporaryObject(materialPair, testCase, { appearance: appearance, raised: raised });
                    const slot = findChild(pair, "baseSlot");
                    const base = baseComponent.createObject(slot, { tokens: pair.pairTokensRef, raised: raised });
                    base.anchors.fill = slot;
                    const current = findChild(pair, "current");
                    const label = JSON.stringify(appearance) + " raised=" + raised;
                    compare(structure(current), structure(base), label + ": visible structure");
                    compare(findChild(current, "materialShadowEffect"), null, label);
                    waitForRendering(pair);
                    const image = grabImage(pair);
                    let same = true;
                    for (let y = 0; y < 260 && same; y += 1) {
                        for (let x = 0; x < 300 && same; x += 1) {
                            same = String(image.pixel(x, y)) === String(image.pixel(x + 300, y));
                        }
                    }
                    verify(same, label + ": same pixels as f582426");
                    base.destroy();
                    pair.destroy();
                    wait(0);
                }
            }
        }
    }

    function test_light_material_uses_the_soft_paths() {
        const pair = createTemporaryObject(materialPair, testCase, { appearance: lightTheme });
        const current = findChild(pair, "current");
        verify(current.shadowPath === "layered" || current.shadowPath === "effect");
        verify(structure(current).length > 2);
    }

    function test_legacy_backdrop_is_the_flat_background() {
        for (const theme of legacyThemes) {
            tokens.appearance = theme;
            const backdrop = createTemporaryObject(backdropFactory, testCase, { tokens: tokens });
            const flat = createTemporaryObject(flatFactory, testCase, { color: tokens.background });
            waitForRendering(backdrop);
            verify(grabImage(backdrop).equals(grabImage(flat)), JSON.stringify(theme));
        }
    }

    Component { id: backdropFactory; Jelly.Backdrop { width: 320; height: 200 } }
    Component { id: flatFactory; Rectangle { width: 320; height: 200 } }
}
