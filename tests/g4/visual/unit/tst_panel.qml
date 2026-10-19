import QtQuick
import QtTest
import Quickshell
import Quickshell.Services.Pipewire
import Quickshell.Networking
import DittoStub
import "../../../../shell/jelly" as Jelly
import "../.staged/capture-data.js" as Theme
import "../.staged/i18n-data.js" as Catalogue

// Actual provider; layer-shell, system services and Core are fixtures.
TestCase {
    id: testCase
    name: "PanelTopRecipe"
    width: 1280; height: 800
    visible: true
    when: windowShown
    Item { id: desktop; width: 1280; height: 800 }
    Jelly.Tokens { id: tokens }
    QtObject {
        id: client
        property bool online: true
        property string status: "offline fixture"
        property bool allowed: true
        property var calls: []
        // The Shell's translator (shell/core/Tr.qml) exposes the Ditto language.
        property var tr: ({ language: "zh-TW" })
        property var windows: [{ id: "w1", title: "Focused fixture", focused: true }]
        property var workspaces: [
            { id: "1", name: "1", active: true }, { id: "2", name: "2", active: false },
            { id: "3", name: "3", active: false }, { id: "4", name: "4", active: false }
        ]
        // The real runtime catalogues (shell/i18n/ditto_*.json, staged by
        // capture/prepare.py), looked up like shell/core/Tr.qml does.
        function t(text) {
            const hit = tr && tr.language === "en" ? Catalogue.en[text] : undefined;
            return hit !== undefined && hit !== "" ? hit : text;
        }
        function capabilityAvailable(id) { return allowed; }
        function activateWorkspace(id) { calls = calls.concat([id]); }
        function launchApp(id) { calls = calls.concat([id]); }
        function capability(id, args) { calls = calls.concat([id + ":" + (args.command_id || "")]); }
    }
    QtObject { id: audio; property bool muted: false; property real volume: 0.5 }
    QtObject { id: sink; property var audio: testCase.audioObject }
    readonly property var audioObject: audio
    property var mounted: []
    property date comparisonTime: new Date()
    function init() {
        StubDesktop.layer = desktop;
        StubDesktop.screenWidth = 1280;
        client.workspaces = Array.from({ length: 4 }, (_, i) => ({ id: String(i + 1), name: String(i + 1), active: i === 0 }));
        tokens.appearance = { theme: "soft-jelly-light", tokens: {} };
        client.allowed = true; client.online = true; client.calls = [];
        client.tr = { language: "zh-TW" };
        client.windows = [{ id: "w1", title: "Focused fixture", focused: true }];
        comparisonTime = new Date();
        Pipewire.ready = false; Pipewire.defaultAudioSink = null;
        Networking.backend = NetworkBackendType.None;
        Networking.connectivity = NetworkConnectivity.Unknown;
        Networking.devices = null;
        audio.muted = false; audio.volume = 0.5;
        Quickshell.iconMap = {};
    }
    function cleanup() {
        for (const p of mounted) { p.release(); p.destroy(); }
        mounted = [];
        wait(0);
    }
    function mount(base) {
        const c = Qt.createComponent(Qt.resolvedUrl(base ? "../.staged/base/PanelTop.qml" : "../.staged/providers/PanelTop.qml"));
        verify(c.status === Component.Ready, c.errorString());
        const p = c.createObject(testCase, { client: client, tokens: tokens, shown: true });
        verify(p !== null);
        // The legacy pixel oracle fixes both stub clocks to the same captured
        // instant; mounting across a minute boundary must not compare two times.
        if (!tokens.lightRecipe) p.data.find(x => x.precision !== undefined).date = comparisonTime;
        mounted.push(p);
        wait(20);
        return p;
    }
    function item(name) {
        const found = findChild(desktop, name);
        verify(found !== null, name + " exists");
        return found;
    }
    function test_geometry_and_region() {
        const p = mount();
        const capsule = item("panelWorkspaces");
        compare(capsule.x + capsule.width / 2, 640);
        compare(capsule.y, 4); compare(capsule.width, 144); compare(capsule.height, 28);
        const status = item("panelStatus");
        compare(status.x + status.width, 1262);
        verify(status.x > capsule.x + capsule.width + 8);
        compare(item("panelTitle").text, "Focused fixture");
        verify(p.statusRegion === item("panelStatusItems"));
        const window = p.data.find(x => x.exclusiveZone !== undefined);
        compare(window.exclusiveZone, 36); compare(window.height, 36);
        verify(window.mask !== null);
        verify(!window.mask.contains(0, 0));
        verify(!window.mask.contains(500, 18));
        verify(window.mask.contains(640, 18));
        verify(!window.mask.contains(capsule.x, capsule.y));
        p.release(); compare(window.exclusiveZone, 0);
    }
    function test_workspace_capability_and_keyboard() {
        mount();
        const button = item("panelWorkspace_2");
        button.forceActiveFocus(); keyClick(Qt.Key_Return); keyClick(Qt.Key_Space);
        mouseClick(button); compare(client.calls, ["2", "2", "2"]);
        client.allowed = false;
        button.forceActiveFocus(); keyClick(Qt.Key_Return); keyClick(Qt.Key_Space); mouseClick(button);
        compare(client.calls, ["2", "2", "2"]);
    }
    function test_status_states_and_fallback() {
        mount();
        const volume = item("panelVolume"); const network = item("panelNetwork");
        compare(volume.Accessible.name, "音量不可用");
        compare(network.Accessible.name, "網路不可用");
        compare(network.marker, "!");
        verify(item("panelVolumeFallback").visible);
        const unavailable = volume.iconName;
        Pipewire.ready = true; Pipewire.defaultAudioSink = sink;
        compare(volume.Accessible.name, "音量 50%");
        verify(volume.iconName !== unavailable);
        audio.muted = true;
        compare(volume.Accessible.name, "音量 靜音");
        compare(volume.iconName, "audio-volume-muted-symbolic");
        Networking.backend = NetworkBackendType.NetworkManager;
        compare(network.Accessible.name, "網路狀態未知");
        compare(network.marker, "?");
        const unknown = network.iconName;
        Networking.connectivity = NetworkConnectivity.None;
        Networking.devices = { values: [{ type: DeviceType.Wifi, connected: false }] };
        compare(network.Accessible.name, "網路未連線");
        verify(network.iconName !== unknown);
        Networking.devices = { values: [{ type: DeviceType.Wifi, connected: true }] };
        compare(network.Accessible.name, "網路已連線");
        Quickshell.iconMap = {
            "audio-volume-muted-symbolic": Qt.resolvedUrl("../fixtures/test-icon.svg"),
            "network-wireless-signal-excellent-symbolic": Qt.resolvedUrl("../fixtures/test-icon.svg")
        };
        tryCompare(item("panelVolumeIcon"), "status", Image.Ready);
        tryCompare(item("panelNetworkIcon"), "status", Image.Ready);
        verify(!item("panelVolumeFallback").visible);
        verify(!item("panelNetworkFallback").visible);
        Quickshell.iconMap = {};
        tryVerify(() => item("panelNetworkFallback").visible);
        verify(item("panelNetworkFallback").text.length > 0);
    }
    function test_motion_focus_and_actions() {
        const p = mount();
        const button = item("panelWorkspace_2");
        button.forceActiveFocus();
        tryCompare(button, "feedbackScale", 0.96);
        verify(item("panelWorkspace_2_focus").visible);
        mousePress(button);
        tryCompare(button, "feedbackScale", 0.90);
        tokens.appearance = { theme: "soft-jelly-light", reduced_motion: true, tokens: {} };
        verify(!button.motionRunning);
        mouseRelease(button);
        compare(button.feedbackScale, 0.96);
        const menu = item("panelMenu");
        menu.forceActiveFocus(); keyClick(Qt.Key_Space); compare(p.menuOpen, true);
        const entries = [];
        function walk(root) {
            for (const child of root.children) {
                if (child.visible && child.Accessible.role === Accessible.MenuItem) entries.push(child);
                walk(child);
            }
        }
        walk(desktop);
        compare(entries.length, 9);
        entries[1].forceActiveFocus(); keyClick(Qt.Key_Return);
        verify(client.calls.indexOf("desktop.commands.invoke:composition.open") >= 0);
        item("panelVolume").forceActiveFocus(); keyClick(Qt.Key_Return);
        verify(client.calls.indexOf("pavucontrol") >= 0);
        item("panelNetwork").forceActiveFocus(); keyClick(Qt.Key_Space);
        verify(client.calls.indexOf("nm-connection-editor") >= 0);
    }
    function test_tab_order_and_status_controls() {
        mount();
        item("panelMenu").forceActiveFocus();
        for (const name of ["panelWorkspace_1", "panelWorkspace_2", "panelWorkspace_3", "panelWorkspace_4", "panelNetwork", "panelVolume"]) {
            keyClick(Qt.Key_Tab);
            verify(item(name).activeFocus, name + " follows visual order");
        }
        Pipewire.ready = true; Pipewire.defaultAudioSink = sink;
        const volume = item("panelVolume");
        mouseClick(volume); compare(audio.muted, true);
        mouseWheel(volume, volume.width / 2, volume.height / 2, 0, 120);
        compare(audio.volume, 0.55);
        mouseClick(volume, volume.width / 2, volume.height / 2, Qt.RightButton);
        compare(client.calls, ["pavucontrol"]);
        keyClick(Qt.Key_Backtab); verify(item("panelNetwork").activeFocus);
    }
    function test_modes_font_scale_and_status_slot() {
        const p = mount();
        for (const extra of [{}, { reduced_transparency: true }, { low_power_style: true }, { tokens: { font_scale: 2 } }]) {
            tokens.appearance = Object.assign({ theme: "soft-jelly-light", tokens: {} }, extra);
            wait(0);
            const ws = item("panelWorkspaces");
            const status = item("panelStatus");
            compare(ws.x + ws.width / 2, 640);
            compare(status.x + status.width, 1262);
            verify(ws.x + ws.width < status.x);
            const window = p.data.find(x => x.exclusiveZone !== undefined);
            compare(window.exclusiveZone, ws.height + 8);
            if (extra.reduced_transparency) compare(status.color.a, 1);
        }
        tokens.appearance = { theme: "soft-jelly-light", tokens: {} };
        const member = Qt.createQmlObject('import QtQuick; Rectangle { width: 40; height: 18; color: "red" }', p.statusRegion);
        tryCompare(p.statusRegion, "width", 40);
        verify(member.visible);
        verify(item("panelStatus").width >= 242);
        member.destroy();
    }
    function test_icon_error_still_has_text() {
        mount();
        Quickshell.iconMap = { "audio-card-symbolic": Qt.resolvedUrl("../fixtures/does-not-exist.svg") };
        tryCompare(item("panelVolumeIcon"), "status", Image.Error);
        verify(item("panelVolumeFallback").visible);
        compare(item("panelVolumeFallback").text, "音量不可用");
    }
    function test_status_region_survives_theme_switch() {
        const p = mount();
        const region = p.statusRegion;
        const member = Qt.createQmlObject('import QtQuick; Rectangle { width: 40; height: 18; color: "red" }', region);
        for (const theme of ["soft-jelly", "soft-jelly-light", "other", "soft-jelly-light"]) {
            tokens.appearance = { theme: theme, tokens: {} };
            wait(0);
            compare(p.statusRegion, region, "the host retains its region and mounted members");
            verify(member.visible, "status member stays visible without host remount");
            compare(member.parent, p.statusRegion);
        }
        member.destroy();
    }
    function test_menu_feedback_and_lifecycle() {
        const p = mount();
        item("panelMenu").forceActiveFocus(); keyClick(Qt.Key_Return);
        let entry = null;
        function walk(root) {
            for (const child of root.children) {
                if (child.visible && child.Accessible.role === Accessible.MenuItem && child.Accessible.name === "組合中心") entry = child;
                walk(child);
            }
        }
        walk(desktop);
        verify(entry !== null, "composition menu entry exists");
        entry.forceActiveFocus();
        const text = entry.children.find(child => child.text !== undefined);
        tryCompare(text, "scale", 0.96);
        mousePress(entry); tryCompare(text, "scale", 0.90);
        tokens.appearance = { theme: "soft-jelly-light", reduced_motion: true, tokens: {} };
        verify(!entry.motionRunning);
        mouseRelease(entry);
        p.release();
        verify(!entry.motionRunning);
        compare(item("panelMenu").feedbackScale, 1);
        verify(!item("panelMenu").motionRunning);
    }
    function test_legacy_pixels() {
        for (const appearance of [null, { theme: "soft-jelly", tokens: {} }, { theme: "other", tokens: {} }]) {
            tokens.appearance = appearance;
            const base = mount(true);
            Qt.createQmlObject('import QtQuick; Rectangle { width: 40; height: 18; color: "red" }', base.statusRegion);
            waitForRendering(desktop);
            const before = grabImage(desktop);
            base.release(); base.destroy(); mounted = []; wait(20);
            const current = mount();
            Qt.createQmlObject('import QtQuick; Rectangle { width: 40; height: 18; color: "red" }', current.statusRegion);
            waitForRendering(desktop);
            const after = grabImage(desktop);
            verify(before.equals(after), "legacy panel pixels match bound base");
            current.release(); current.destroy(); mounted = []; wait(20);
        }
    }
    function test_layout_matrix_data() {
        const rows = [];
        for (const width of [1280, 1024, 800, 640])
            for (const scale of [1, 1.5, 2])
                for (const count of [4, 9, 10])
                    for (const icons of [false, true])
                        for (const members of [0, 2])
                            rows.push({ tag: [width, scale, count, icons, members].join("-"), width, scale, count, icons, members });
        return rows;
    }
    function inside(item, capsule, context) {
        if (!item.visible || item.width === 0 || item.height === 0) return;
        const p = item.mapToItem(capsule, 0, 0);
        verify(p.x >= -0.1 && p.y >= -0.1 && p.x + item.width <= capsule.width + 0.1
               && p.y + item.height <= capsule.height + 0.1, context + " fits capsule: " + [p.x, p.y, item.width, item.height, capsule.width, capsule.height]);
        for (const child of item.children) inside(child, capsule, context);
    }
    function test_layout_matrix(data) {
        StubDesktop.screenWidth = data.width;
        tokens.appearance = { theme: "soft-jelly-light", tokens: { font_scale: data.scale } };
        client.workspaces = Array.from({ length: data.count }, (_, i) => ({ id: String(i + 1), name: String(i + 1), active: i === 0 }));
        if (data.icons) Quickshell.iconMap = {
            "audio-card-symbolic": Qt.resolvedUrl("../fixtures/test-icon.svg"),
            "network-error-symbolic": Qt.resolvedUrl("../fixtures/test-icon.svg")
        };
        const p = mount();
        for (let i = 0; i < data.members; ++i) Qt.createQmlObject('import QtQuick; Rectangle { width: ' + (40 * data.scale) + '; height: 18; color: "red" }', p.statusRegion);
        if (data.icons) {
            tryCompare(item("panelVolumeIcon"), "status", Image.Ready);
            tryCompare(item("panelNetworkIcon"), "status", Image.Ready);
        }
        wait(30); // positioner polish after the last service/member update
        const capsules = [item("panelLeft"), item("panelWorkspaces"), item("panelStatus")];
        const window = p.data.find(x => x.exclusiveZone !== undefined);
        compare(window.width, data.width);
        for (let i = 0; i < capsules.length; ++i) {
            const c = capsules[i];
            verify(c.x >= 0 && c.x + c.width <= data.width, "capsule stays on screen");
            if (i) verify(capsules[i - 1].x + capsules[i - 1].width + 8 <= c.x, "capsules and Regions do not overlap");
            inside(c, c, "capsule " + i);
            verify(c.radius <= Math.floor(Math.max(28, tokens.fontSmall + 12) / 2), "wrapped content keeps the single-row corner radius");
            const region = window.mask.regions[i];
            compare(region.item, c);
            compare(region.radius, c.radius);
            verify(region.contains(c.width / 2, c.height / 2));
            verify(!region.contains(0, 0));
            if (i) verify(!window.mask.contains((capsules[i - 1].x + capsules[i - 1].width + c.x) / 2, 18));
        }
        compare(window.exclusiveZone, Math.max(...capsules.map(c => c.height)) + 8);
        // #105 C1: common widths and font sizes reserve at most two rows.
        const rowHeight = Math.max(28, tokens.fontSmall + 12);
        if (data.width >= 800 && data.scale <= 1.5)
            verify(Math.max(...capsules.map(c => c.height)) <= 2 * rowHeight,
                   "at most two rows: " + capsules.map(c => c.height) + " row " + rowHeight);
        const strip = item("panelStatusStrip");
        if (strip.height > rowHeight)
            verify(capsules[2].width <= strip.width + 16 + 0.5, "a wrapped status capsule fits its content: "
                   + capsules[2].width + " for " + strip.width);
        if (data.width === 1280 && data.scale === 1 && data.count === 4 && data.members === 0 && data.icons) {
            compare(capsules[1].x, 568); compare(capsules[1].width, 144);
            compare(capsules[2].x, 1020); compare(capsules[2].width, 242);
        }
    }
    function test_disabled_workspace_is_inert() {
        mount();
        client.allowed = false;
        const button = item("panelWorkspace_2");
        mouseMove(button, button.width / 2, button.height / 2);
        mousePress(button); wait(150);
        compare(button.feedbackScale, 1);
        verify(!button.motionRunning);
        verify(!button.enabled);
        mouseRelease(button);
        item("panelMenu").forceActiveFocus(); keyClick(Qt.Key_Tab);
        verify(item("panelNetwork").activeFocus, "disabled workspace buttons are absent from Tab order");
        client.allowed = true;
        button.forceActiveFocus(); tryCompare(button, "feedbackScale", 0.96);
    }
    function test_symbolic_tint_and_mute_marker() {
        Quickshell.iconMap = { "audio-volume-muted-symbolic": Qt.resolvedUrl("../fixtures/half-opacity-symbolic.svg") };
        Pipewire.ready = true; Pipewire.defaultAudioSink = sink; audio.muted = true;
        mount();
        const icon = item("panelVolumeIcon");
        tryCompare(icon, "status", Image.Ready);
        compare(icon.width, 18); compare(icon.height, 18);
        compare(icon.color, tokens.foreground);
        const volume = item("panelVolume");
        verify(volume.marker !== "");
        compare(volume.tooltipText, volume.Accessible.name);
        verify(item("panelVolumeMarker").visible);
        tryVerify(() => icon.painted);
        waitForRendering(icon);
        const pixels = grabImage(desktop);
        const pos = icon.mapToItem(desktop, 9, 9);
        const centre = pixels.pixel(Math.round(pos.x), Math.round(pos.y));
        const capsule = item("panelStatus");
        // Capsule padding: centred content (#105 C3) may start at x + 20.
        const surface = pixels.pixel(capsule.x + 8, capsule.y + capsule.height / 2);
        // #105 O1: an icon with no opaque pixel at all (here a single 50%
        // square) is raised to full strength; mixed icons keep their source
        // alpha (test_mixed_icon_keeps_source_alpha, Yaru volume levels).
        verify(contrast(centre, surface) >= 4.5, "dim-only graphics are raised above 4.5:1");
        for (const channel of ["r", "g", "b"])
            fuzzyCompare(centre[channel], tokens.foreground[channel], 1.1 / 255, "dim-only icon drawn at full strength: " + channel);
        verify(icon.normalized, "the minimum-alpha rule applied");
    }
    function test_mixed_icon_keeps_source_alpha() {
        Quickshell.iconMap = { "audio-volume-high-symbolic": Qt.resolvedUrl("../capture/fixtures/mixed-opacity-symbolic.svg") };
        Pipewire.ready = true; Pipewire.defaultAudioSink = sink; audio.volume = 1;
        mount();
        const icon = item("panelVolumeIcon");
        tryCompare(icon, "status", Image.Ready);
        tryVerify(() => icon.painted);
        verify(!icon.normalized, "an icon with an opaque part keeps its source alpha");
        const pixels = grabImage(desktop);
        const capsule = item("panelStatus");
        const surface = pixels.pixel(capsule.x + 8, capsule.y + capsule.height / 2);
        const solid = icon.mapToItem(desktop, 4, 9), half = icon.mapToItem(desktop, 13, 9);
        const a = pixels.pixel(Math.round(solid.x), Math.round(solid.y)), b = pixels.pixel(Math.round(half.x), Math.round(half.y));
        const alpha = 127 / 255;
        for (const channel of ["r", "g", "b"]) {
            fuzzyCompare(a[channel], tokens.foreground[channel], 1.1 / 255, "opaque part: " + channel);
            fuzzyCompare(b[channel], tokens.foreground[channel] * alpha + surface[channel] * (1 - alpha), 1.1 / 255,
                         "source 50% alpha is preserved: " + channel);
        }
    }
    function test_light_menu_alignment() {
        const p = mount();
        p.menuOpen = true; wait(0);
        const menu = p.data.find(x => x.anchor !== undefined);
        compare(menu.anchor.rect.x, item("panelLeft").x);
    }
    function test_legacy_interactions_data() {
        const rows = [];
        for (const theme of ["none", "soft-jelly", "other"])
            for (const scale of [1, 2])
                for (const width of [1280, 800]) rows.push({ tag: [theme, scale, width].join("-"), theme, scale, width });
        return rows;
    }
    function descendants(root, role) {
        const found = [];
        for (const child of root.children) {
            if (!child.visible) continue;
            if (child.Accessible.role === role) found.push(child);
            found.push(...descendants(child, role));
        }
        return found;
    }
    function legacyInteractionSnapshot(base) {
        client.calls = [];
        mouseMove(desktop, 600, 400);
        const p = mount(base);
        const window = p.data.find(x => x.exclusiveZone !== undefined);
        Qt.createQmlObject('import QtQuick; Rectangle { width: 40; height: 18; color: "red" }', p.statusRegion);
        wait(20);
        const buttons = descendants(window.contentItem, Accessible.Button).filter(button => button.activeFocusOnTab);
        compare(buttons.length, 5);
        compare(window.height, 34); compare(window.exclusiveZone, 34);
        compare(window.mask, null);
        const statusPos = p.statusRegion.mapToItem(window.contentItem, 0, 0);
        const result = { status: [statusPos.x, statusPos.y, p.statusRegion.width, p.statusRegion.height], pixels: [], order: [] };
        buttons[0].forceActiveFocus();
        waitForRendering(desktop); result.pixels.push(grabImage(desktop));
        for (let i = 0; i < 4; ++i) {
            keyClick(Qt.Key_Tab);
            const focused = buttons.find(button => button.activeFocus);
            verify(focused !== undefined);
            result.order.push(focused.Accessible.name);
        }
        buttons[1].forceActiveFocus(); keyClick(Qt.Key_Return);
        mouseClick(buttons[2]);
        result.calls = client.calls;
        compare(result.calls, ["1", "2"]);
        buttons[0].forceActiveFocus(); keyClick(Qt.Key_Return);
        compare(p.menuOpen, true);
        waitForRendering(desktop); result.pixels.push(grabImage(desktop));
        const entries = descendants(desktop, Accessible.MenuItem);
        compare(entries.length, 9);
        entries[1].forceActiveFocus();
        waitForRendering(desktop); result.pixels.push(grabImage(desktop));
        mouseMove(entries[2], entries[2].width / 2, entries[2].height / 2);
        waitForRendering(desktop); result.pixels.push(grabImage(desktop));
        p.release(); compare(window.exclusiveZone, 0);
        p.destroy(); mounted = mounted.filter(object => object !== p); wait(20);
        return result;
    }
    function test_legacy_interactions(data) {
        StubDesktop.screenWidth = data.width;
        tokens.appearance = data.theme === "none" ? { tokens: { font_scale: data.scale } }
            : { theme: data.theme, tokens: { font_scale: data.scale } };
        const before = legacyInteractionSnapshot(true);
        const after = legacyInteractionSnapshot(false);
        compare(after.status, before.status);
        compare(after.order, before.order);
        compare(after.calls, before.calls);
        for (let i = 0; i < before.pixels.length; ++i)
            verify(before.pixels[i].equals(after.pixels[i]), "legacy focus/menu/hover pixels match phase " + i);
    }
    function luminance(color) {
        const linear = x => x <= 0.04045 ? x / 12.92 : Math.pow((x + 0.055) / 1.055, 2.4);
        return linear(color.r) * 0.2126 + linear(color.g) * 0.7152 + linear(color.b) * 0.0722;
    }
    function contrast(a, b) {
        return (Math.max(luminance(a), luminance(b)) + 0.05) / (Math.min(luminance(a), luminance(b)) + 0.05);
    }
    function renderedPixels(target, width, height) {
        waitForRendering(desktop, 250);
        const image = grabImage(desktop);
        const p = target.mapToItem(desktop, 0, 0);
        const pixels = [];
        for (let y = 0; y < height; ++y)
            for (let x = 0; x < width; ++x) pixels.push(image.pixel(Math.round(p.x) + x, Math.round(p.y) + y));
        return pixels;
    }
    function test_yaru_volume_levels_remain_distinct() {
        Quickshell.iconMap = Theme.yaruIconMap;
        Pipewire.ready = true; Pipewire.defaultAudioSink = sink;
        mount();
        const button = item("panelVolume");
        const icon = item("panelVolumeIcon");
        const samples = [];
        for (const state of [{ volume: 0, muted: false, name: "low" }, { volume: 0.4, muted: false, name: "medium" },
                             { volume: 1, muted: false, name: "high" }, { volume: 0.4, muted: true, name: "muted" }]) {
            const iconName = "audio-volume-" + state.name + "-symbolic";
            verify(String(Theme.yaruIconMap[iconName]).indexOf("/Yaru/") >= 0, "real Yaru fixture from capture/prepare.py: " + iconName);
            audio.volume = state.volume; audio.muted = state.muted;
            tryCompare(button, "iconName", iconName);
            tryCompare(icon, "status", Image.Ready);
            compare(String(icon.source), String(Theme.yaruIconMap[iconName]));
            samples.push(renderedPixels(icon, 18, 18));
            const pixels = renderedPixels(button, Math.floor(button.width), Math.floor(button.height));
            const capsule = item("panelStatus");
            const surface = grabImage(desktop).pixel(capsule.x + 20, capsule.y + capsule.height / 2);
            verify(Math.max(...pixels.map(pixel => contrast(pixel, surface))) >= 4.5,
                   "opaque speaker core or mute marker retains F2 contrast");
        }
        for (let a = 0; a < samples.length; ++a) {
            for (let b = a + 1; b < samples.length; ++b) {
                let count = 0;
                for (let i = 0; i < samples[a].length; ++i)
                    if (Math.max(...["r", "g", "b"].map(c => Math.abs(samples[a][i][c] - samples[b][i][c]))) * 255 >= 64) ++count;
                console.log("VOLUME_DIFF " + JSON.stringify({ states: [a, b], pixels_delta_at_least_64: count }));
                verify(count >= 6, "Yaru states " + a + "/" + b + " differ in >=6 pixels by >=64/255; got " + count);
            }
        }
    }
    function test_yaru_error_badge_keeps_semantic_color() {
        Quickshell.iconMap = Theme.yaruIconMap;
        verify(String(Theme.yaruIconMap["network-error-symbolic"]).indexOf("/Yaru/") >= 0);
        mount();
        const icon = item("panelNetworkIcon");
        tryCompare(icon, "status", Image.Ready);
        const pixels = renderedPixels(icon, 18, 18);
        const dangerPixels = pixels.filter(pixel => String(pixel) === String(tokens.danger)).length;
        verify(dangerPixels >= 8, "error badge retains >=8 opaque semantic danger pixels; got " + dangerPixels);
        const capsule = item("panelStatus");
        const surface = grabImage(desktop).pixel(capsule.x + 20, capsule.y + capsule.height / 2);
        verify(contrast(tokens.danger, surface) >= 3);
    }
    function test_status_description_does_not_repeat_name() {
        mount();
        for (const name of ["panelNetwork", "panelVolume"]) {
            const button = item(name);
            compare(button.Accessible.description, "");
            compare(button.tooltipText, button.Accessible.name);
        }
        verify(item("panelMenu").Accessible.description.length > 0, "menu keeps its supplemental window information");
    }

    // ---- #102 B1: keyboard mute; Accessible press/toggle use the same paths.
    function test_volume_keyboard_mute_and_actions() {
        Pipewire.ready = true; Pipewire.defaultAudioSink = sink; audio.muted = false;
        mount();
        const volume = item("panelVolume");
        volume.forceActiveFocus();
        keyClick(Qt.Key_Space);
        compare(audio.muted, true, "Space mutes");
        compare(client.calls, [], "Space does not open the settings");
        compare(volume.Accessible.name, "音量 靜音");
        verify(volume.Accessible.checkable, "mute is exposed as a toggle state");
        compare(volume.Accessible.checked, true);
        keyClick(Qt.Key_Space);
        compare(audio.muted, false, "Space unmutes");
        compare(volume.Accessible.checked, false);
        compare(volume.Accessible.name, "音量 50%");
        keyClick(Qt.Key_Return);
        compare(client.calls, ["pavucontrol"], "Enter opens the settings");
        compare(audio.muted, false);
        keyClick(Qt.Key_Enter);
        compare(client.calls, ["pavucontrol", "pavucontrol"], "keypad Enter too");
        volume.Accessible.toggleAction();
        compare(audio.muted, true, "the toggle action mutes");
        volume.Accessible.pressAction();
        compare(client.calls.length, 3, "the press action opens the settings");
        compare(audio.muted, true);
        compare(volume.Accessible.description, "", "no description that repeats the name (N3)");
        compare(volume.tooltipText, volume.Accessible.name);
        // Mouse paths are unchanged.
        mouseClick(volume); compare(audio.muted, false);
        // Without audio there is nothing to mute: Space keeps opening the
        // settings, the toggle action does nothing.
        Pipewire.ready = false;
        compare(volume.Accessible.name, "音量不可用");
        verify(!volume.Accessible.checkable);
        volume.forceActiveFocus();
        keyClick(Qt.Key_Space);
        compare(client.calls.length, 4);
        volume.Accessible.toggleAction();
        compare(client.calls.length, 4);
    }

    // ---- #102 B2: the network icon follows the Networking device type.
    function test_network_icon_by_device_type_data() {
        const wired = DeviceType.Wired, wifi = DeviceType.Wifi, other = DeviceType.None;
        const full = NetworkConnectivity.Full, none = NetworkConnectivity.None, unknown = NetworkConnectivity.Unknown;
        const on = "網路已連線", off = "網路未連線", what = "網路狀態未知";
        return [
            { tag: "wired-connected", devices: [{ type: wired, connected: true }], connectivity: full, icon: "network-wired-symbolic", name: on, marker: "" },
            { tag: "wired-disconnected", devices: [{ type: wired, connected: false }], connectivity: none, icon: "network-wired-disconnected-symbolic", name: off, marker: "" },
            { tag: "wired-unknown", devices: [{ type: wired, connected: false }], connectivity: unknown, icon: "network-wired-acquiring-symbolic", name: what, marker: "?" },
            { tag: "wireless-connected", devices: [{ type: wifi, connected: true }], connectivity: full, icon: "network-wireless-signal-excellent-symbolic", name: on, marker: "" },
            { tag: "wireless-disconnected", devices: [{ type: wifi, connected: false }], connectivity: none, icon: "network-wireless-offline-symbolic", name: off, marker: "" },
            { tag: "wireless-unknown", devices: [{ type: wifi, connected: false }], connectivity: unknown, icon: "network-wireless-acquiring-symbolic", name: what, marker: "?" },
            { tag: "other-connected", devices: [{ type: other, connected: true }], connectivity: full, icon: "network-transmit-receive-symbolic", name: on, marker: "" },
            { tag: "other-disconnected", devices: [], connectivity: none, icon: "network-offline-symbolic", name: off, marker: "" },
            { tag: "other-unknown", devices: [], connectivity: unknown, icon: "network-idle-symbolic", name: what, marker: "?" },
            { tag: "wired-preferred-when-both-connected", devices: [{ type: wifi, connected: true }, { type: wired, connected: true }], connectivity: full, icon: "network-wired-symbolic", name: on, marker: "" },
            { tag: "connected-wireless-over-idle-wired", devices: [{ type: wired, connected: false }, { type: wifi, connected: true }], connectivity: full, icon: "network-wireless-signal-excellent-symbolic", name: on, marker: "" },
            { tag: "wireless-preferred-when-both-disconnected", devices: [{ type: wired, connected: false }, { type: wifi, connected: false }], connectivity: none, icon: "network-wireless-offline-symbolic", name: off, marker: "" },
            { tag: "unavailable", backend: false, devices: null, connectivity: unknown, icon: "network-error-symbolic", name: "網路不可用", marker: "!" }
        ];
    }
    function test_network_icon_by_device_type(row) {
        Networking.backend = row.backend === false ? NetworkBackendType.None : NetworkBackendType.NetworkManager;
        Networking.connectivity = row.connectivity;
        Networking.devices = row.devices === null ? null : { values: row.devices };
        Quickshell.iconMap = Theme.yaruIconMap;
        mount();
        const network = item("panelNetwork");
        compare(network.iconName, row.icon);
        compare(network.Accessible.name, row.name, "text names are unchanged");
        compare(network.marker, row.marker);
        verify(String(Theme.yaruIconMap[row.icon]).indexOf("/Yaru/") >= 0, "Yaru provides " + row.icon);
        tryCompare(item("panelNetworkIcon"), "status", Image.Ready);
        verify(!item("panelNetworkFallback").visible);
        // A theme without the icon keeps the existing text fallback.
        const missing = Object.assign({}, Theme.yaruIconMap);
        delete missing[row.icon];
        Quickshell.iconMap = missing;
        tryVerify(() => item("panelNetworkFallback").visible);
        compare(item("panelNetworkFallback").text, row.name);
    }

    // ---- #102 B3: the clock follows the Ditto language, with the weekday.
    function test_clock_follows_ditto_language() {
        Quickshell.iconMap = Theme.yaruIconMap;
        const p = mount();
        tryCompare(item("panelNetworkIcon"), "status", Image.Ready);
        tryCompare(item("panelVolumeIcon"), "status", Image.Ready);
        p.data.find(x => x.precision !== undefined).date = new Date(2026, 9, 19, 14, 5, 42);
        const clock = item("panelClock");
        compare(clock.text, "10月19日 週一 14:05");
        compare(clock.Accessible.name, clock.text);
        client.tr = { language: "en" };
        compare(clock.text, "Mon Oct 19 14:05");
        compare(clock.Accessible.name, clock.text);
        client.tr = { language: "zh-TW" };
        compare(clock.text, "10月19日 週一 14:05");
        // The wider text is part of the measured layout and the input region.
        const capsule = item("panelStatus");
        inside(clock, capsule, "clock");
        const window = p.data.find(x => x.exclusiveZone !== undefined);
        const c = clock.mapToItem(capsule, clock.width / 2, clock.height / 2);
        verify(window.mask.regions[2].contains(c.x, c.y), "clock is inside the status Region");
        // With icons, the 1280 reference geometry holds in both languages.
        for (const language of ["zh-TW", "en"]) {
            client.tr = { language: language };
            wait(0);
            compare(capsule.x, 1020, language); compare(capsule.width, 242, language);
            compare(item("panelWorkspaces").x, 568, language);
        }
    }

    // ---- #105 C1: a two-column step, workspaces wrap first, menu near Ditto.
    function narrowMount(width, scale, count, icons, members) {
        StubDesktop.screenWidth = width;
        tokens.appearance = { theme: "soft-jelly-light", tokens: { font_scale: scale } };
        client.workspaces = Array.from({ length: count }, (_, i) => ({ id: String(i + 1), name: String(i + 1), active: i === 0 }));
        if (icons) Quickshell.iconMap = Theme.yaruIconMap;
        const p = mount();
        for (let i = 0; i < members; ++i)
            Qt.createQmlObject('import QtQuick; Rectangle { width: ' + (40 * scale) + '; height: 18; color: "red" }', p.statusRegion);
        if (icons) {
            tryCompare(item("panelVolumeIcon"), "status", Image.Ready);
            tryCompare(item("panelNetworkIcon"), "status", Image.Ready);
        }
        wait(30);
        return p;
    }
    function test_narrow_steps_data() {
        return [
            // The reviewer's N2 worst case (114 px reserved at dce0242).
            { tag: "800-1-10-text-2", width: 800, scale: 1, count: 10, icons: false, members: 2, rows: 2 },
            { tag: "800-1.5-10-text-2", width: 800, scale: 1.5, count: 10, icons: false, members: 2, rows: 2 },
            { tag: "800-1.5-9-icons-0", width: 800, scale: 1.5, count: 9, icons: true, members: 0, rows: 2 },
            { tag: "1024-1.5-10-text-2", width: 1024, scale: 1.5, count: 10, icons: false, members: 2, rows: 2 },
            { tag: "1024-1-9-icons-0", width: 1024, scale: 1, count: 9, icons: true, members: 0, rows: 1 }
        ];
    }
    function test_narrow_steps(data) {
        const p = narrowMount(data.width, data.scale, data.count, data.icons, data.members);
        const rowHeight = Math.max(28, tokens.fontSmall + 12);
        const ws = item("panelWorkspaces"), status = item("panelStatus"), left = item("panelLeft");
        const window = p.data.find(x => x.exclusiveZone !== undefined);
        const tallest = Math.max(ws.height, status.height, left.height);
        const wsStrip = findChild(ws, "panelWorkspaceStrip"), stStrip = findChild(status, "panelStatusStrip");
        console.log("NARROW " + JSON.stringify({ tag: data.tag, reserved: window.exclusiveZone, row: rowHeight,
            workspace: [ws.x, ws.width, ws.height, wsStrip ? wsStrip.columns : null],
            status: [status.x, status.width, status.height, stStrip ? stStrip.columns : null] }));
        verify(tallest <= data.rows * rowHeight, "at most " + data.rows + " row(s): " + tallest);
        compare(window.exclusiveZone, tallest + 8);
        const statusStrip = item("panelStatusStrip");
        verify(statusStrip.columns >= 2, "a two-column step before one column: " + statusStrip.columns);
        const statusWrapped = statusStrip.height > rowHeight;
        if (statusWrapped) {
            verify(ws.height > rowHeight, "workspaces wrap before the status capsule leaves one row");
            verify(status.width <= statusStrip.width + 16 + 0.5, "the status capsule shrinks to its content");
        }
        // The menu opens just below the Ditto capsule, not below the tallest pill.
        p.menuOpen = true; wait(0);
        const menu = p.data.find(x => x.anchor !== undefined && x.objectName !== "panelTooltipWindow");
        compare(menu.anchor.rect.x, left.x);
        verify(menu.anchor.rect.y >= left.y + left.height && menu.anchor.rect.y <= left.y + left.height + 8,
               "menu " + menu.anchor.rect.y + " below Ditto capsule " + (left.y + left.height));
    }
    function test_default_menu_position_unchanged() {
        const p = mount();
        p.menuOpen = true; wait(0);
        const menu = p.data.find(x => x.anchor !== undefined && x.objectName !== "panelTooltipWindow");
        compare(menu.anchor.rect.y, 36, "1280 default: directly below the 36 px bar, as before");
    }

    // ---- #105 C2: a themed tooltip surface outside the 36 px panel window.
    function test_tooltip_is_a_themed_popup_outside_the_panel() {
        StubDesktop.screenWidth = 800;
        Pipewire.ready = true; Pipewire.defaultAudioSink = sink;
        const p = mount();
        const window = p.data.find(x => x.exclusiveZone !== undefined);
        const popup = p.data.find(x => x.objectName === "panelTooltipWindow");
        verify(popup !== undefined, "the tooltip is a popup surface of its own");
        const box = item("panelTooltip"), text = item("panelTooltipText");
        verify(!box.visible);
        const volume = item("panelVolume");
        mouseMove(volume, volume.width / 2, volume.height / 2);
        tryVerify(() => box.visible, 3000, "hover shows the tooltip");
        compare(text.text, volume.Accessible.name);
        for (let a = box; a; a = a.parent) verify(a !== window.contentItem, "not inside the panel window");
        const r = box.mapToItem(desktop, 0, 0);
        verify(r.y >= window.height, "entirely below the " + window.height + " px panel window: " + r.y);
        verify(r.x >= 0 && r.x + box.width <= 800, "on screen: " + [r.x, box.width]);
        inside(text, box, "tooltip text");
        verify(!text.truncated);
        compare(String(box.color), String(tokens.surfaceStrong));
        compare(String(text.color), String(tokens.foreground));
        verify(contrast(text.color, box.color) >= 4.5);
        verify(popup.mask !== null && !popup.mask.contains(box.width / 2, box.height / 2), "pointer input passes through");
        verify(!popup.grabFocus);
        const anchor = volume.mapToItem(desktop, volume.width / 2, 0);
        verify(Math.abs(r.x + box.width / 2 - anchor.x) <= 1 || r.x + box.width >= 800 - 8, "under its control");
        mouseMove(desktop, 400, 400);
        tryVerify(() => !box.visible, 2000, "leaving hides it");
        const network = item("panelNetwork");
        network.forceActiveFocus();
        tryVerify(() => box.visible, 3000, "keyboard focus shows it too");
        compare(text.text, network.Accessible.name);
        p.release();
        verify(!box.visible, "release hides it");
    }
    function test_long_tooltip_wraps_on_screen() {
        StubDesktop.screenWidth = 800;
        client.windows = [{ id: "w1", focused: true, title: "一個非常長的視窗標題，用來確認提示框會換行而不是被裁切或超出螢幕 — a very long window title" }];
        mount();
        const menu = item("panelMenu");
        menu.forceActiveFocus();
        const box = item("panelTooltip"), text = item("panelTooltipText");
        tryVerify(() => box.visible, 3000);
        compare(text.text, menu.tooltipText);
        const r = box.mapToItem(desktop, 0, 0);
        verify(r.x >= 0 && r.x + box.width <= 800, "on screen");
        verify(box.width <= 360 + 0.5, "bounded width " + box.width);
        verify(text.lineCount >= 2, "long text wraps");
        inside(text, box, "tooltip text");
    }

    // ---- #105 C3: centring without status items; the mute mark stands apart.
    function test_status_content_centred_without_items() {
        mount();
        const capsule = item("panelStatus"), network = item("panelNetwork"), volume = item("panelVolume"), clock = item("panelClock");
        const left = network.mapToItem(capsule, 0, 0).x;
        const right = clock.mapToItem(capsule, 0, 0).x + clock.width;
        console.log("CENTRE " + JSON.stringify({ left: left, right: right, capsule: capsule.width }));
        fuzzyCompare((left + right) / 2, capsule.width / 2, 0.5, "visible content is centred");
        compare(clock.mapToItem(capsule, 0, 0).x - (volume.mapToItem(capsule, 0, 0).x + volume.width), 12,
                "no gap is left for an empty status item area");
    }
    function test_mute_marker_stands_apart_from_the_glyph() {
        Quickshell.iconMap = Theme.yaruIconMap;
        Pipewire.ready = true; Pipewire.defaultAudioSink = sink; audio.muted = true;
        mount();
        const volume = item("panelVolume"), icon = item("panelVolumeIcon"), marker = item("panelVolumeMarker");
        tryCompare(icon, "status", Image.Ready);
        tryVerify(() => icon.painted);
        verify(marker.visible);
        const capsule = item("panelStatus");
        const w = Math.floor(volume.width), h = Math.floor(volume.height);
        const surface = grabImage(desktop).pixel(capsule.x + 8, capsule.y + capsule.height / 2);
        const marked = renderedPixels(volume, w, h);
        volume.marker = "";
        tryVerify(() => !marker.visible);
        const plain = renderedPixels(volume, w, h);
        const changed = i => String(marked[i]) !== String(plain[i]);
        // Marker core: what the marker adds at graphics contrast. Glyph ink:
        // what is still visible ink in the marked render and unchanged by it.
        const core = [], glyph = [];
        for (let i = 0; i < marked.length; ++i) {
            const ratio = contrast(marked[i], surface);
            if (changed(i) && ratio >= 3) core.push(i);
            else if (!changed(i) && ratio >= 1.5) glyph.push(i);
        }
        verify(core.length >= 6, "the marker has an opaque core: " + core.length);
        let clearance = Infinity;
        for (const a of core) for (const b of glyph)
            clearance = Math.min(clearance, Math.max(Math.abs(a % w - b % w), Math.abs(Math.floor(a / w) - Math.floor(b / w))));
        console.log("MARKER " + JSON.stringify({ core: core.length, glyph: glyph.length, clearance: clearance }));
        // Two clear pixels (a 1 px knock-out ring plus one of space, or more)
        // keep the slash from reading as one more sound wave.
        verify(clearance >= 3, "marker core is " + clearance + " px from the glyph's ink; need >= 3");
    }

    // ---- #105 C4: every recoloured symbolic state, real Yaru icons.
    function test_status_state_table_data() {
        const wired = DeviceType.Wired, wifi = DeviceType.Wifi, other = DeviceType.None;
        const full = NetworkConnectivity.Full, none = NetworkConnectivity.None, unknown = NetworkConnectivity.Unknown;
        const rows = [
            { tag: "volume-unavailable", kind: "volume", known: false, icon: "audio-card-symbolic", marker: "!" },
            { tag: "volume-0", kind: "volume", known: true, volume: 0, icon: "audio-volume-low-symbolic", marker: "" },
            { tag: "volume-low", kind: "volume", known: true, volume: 0.2, icon: "audio-volume-low-symbolic", marker: "" },
            { tag: "volume-medium", kind: "volume", known: true, volume: 0.5, icon: "audio-volume-medium-symbolic", marker: "" },
            { tag: "volume-high", kind: "volume", known: true, volume: 1, icon: "audio-volume-high-symbolic", marker: "" },
            { tag: "volume-muted", kind: "volume", known: true, volume: 0.5, muted: true, icon: "audio-volume-muted-symbolic", marker: "∕" },
            { tag: "network-error", kind: "network", backend: false, connectivity: unknown, devices: null, icon: "network-error-symbolic", marker: "!" }
        ];
        for (const type of [{ name: "wired", value: wired }, { name: "wireless", value: wifi }, { name: "other", value: other }]) {
            const icons = {
                wired: ["network-wired-symbolic", "network-wired-disconnected-symbolic", "network-wired-acquiring-symbolic"],
                wireless: ["network-wireless-signal-excellent-symbolic", "network-wireless-offline-symbolic", "network-wireless-acquiring-symbolic"],
                other: ["network-transmit-receive-symbolic", "network-offline-symbolic", "network-idle-symbolic"]
            }[type.name];
            const idle = type.name === "other" ? [] : [{ type: type.value, connected: false }];
            rows.push({ tag: type.name + "-connected", kind: "network", connectivity: full, devices: [{ type: type.value, connected: true }], icon: icons[0], marker: "" });
            rows.push({ tag: type.name + "-disconnected", kind: "network", connectivity: none, devices: idle, icon: icons[1], marker: "" });
            rows.push({ tag: type.name + "-unknown", kind: "network", connectivity: unknown, devices: idle, icon: icons[2], marker: "?" });
        }
        return rows;
    }
    function test_status_state_table(row) {
        Quickshell.iconMap = Theme.yaruIconMap;
        if (row.kind === "volume") {
            Pipewire.ready = row.known; Pipewire.defaultAudioSink = row.known ? sink : null;
            audio.volume = row.volume === undefined ? 0.5 : row.volume; audio.muted = row.muted === true;
        } else {
            Networking.backend = row.backend === false ? NetworkBackendType.None : NetworkBackendType.NetworkManager;
            Networking.connectivity = row.connectivity;
            Networking.devices = row.devices === null ? null : { values: row.devices };
        }
        mount();
        const name = row.kind === "volume" ? "panelVolume" : "panelNetwork";
        const button = item(name), icon = item(name + "Icon");
        compare(button.iconName, row.icon);
        compare(button.marker, row.marker);
        verify(String(Theme.yaruIconMap[row.icon]).indexOf("/Yaru/") >= 0, "real Yaru input: " + row.icon);
        tryCompare(icon, "status", Image.Ready);
        tryVerify(() => icon.painted);
        const capsule = item("panelStatus");
        const pixels = renderedPixels(button, Math.floor(button.width), Math.floor(button.height));
        const surface = grabImage(desktop).pixel(capsule.x + 8, capsule.y + capsule.height / 2);
        const ratios = pixels.map(pixel => contrast(pixel, surface)).filter(ratio => ratio > 1.1).sort((a, b) => a - b);
        const graphic = ratios.filter(ratio => ratio >= 3).length, strong = ratios.filter(ratio => ratio >= 4.5).length;
        console.log("STATUS_STATE " + JSON.stringify({ state: row.tag, icon: row.icon, source: String(icon.source),
            marker: row.marker, text: button.Accessible.name, source_peak_alpha: icon.peakAlpha, raised: icon.normalized,
            ink_pixels: ratios.length, pixels_3_to_1: graphic, pixels_4_5_to_1: strong,
            median: ratios.length ? Number(ratios[Math.floor(ratios.length / 2)].toFixed(2)) : 0,
            max: ratios.length ? Number(ratios[ratios.length - 1].toFixed(2)) : 0 }));
        verify(graphic >= 24, row.tag + ": at least 24 pixels reach 3:1, got " + graphic);
        verify(strong >= 8, row.tag + ": an opaque part or marker carries the state (>=8 pixels at 4.5:1), got " + strong);
    }
}
