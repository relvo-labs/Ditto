import QtQuick
import QtTest
import Quickshell
import Quickshell.Services.Pipewire
import Quickshell.Networking
import DittoStub
import "../../../../shell/jelly" as Jelly
import "../.staged/capture-data.js" as Theme

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
        property var windows: [{ id: "w1", title: "Focused fixture", focused: true }]
        property var workspaces: [
            { id: "1", name: "1", active: true }, { id: "2", name: "2", active: false },
            { id: "3", name: "3", active: false }, { id: "4", name: "4", active: false }
        ]
        function t(text) { return text; }
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
        Networking.devices = { values: [{ connected: false }] };
        compare(network.Accessible.name, "網路未連線");
        verify(network.iconName !== unknown);
        Networking.devices = { values: [{ connected: true }] };
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
        const surface = pixels.pixel(capsule.x + 20, capsule.y + capsule.height / 2);
        verify(contrast(centre, surface) >= 3, "50% graphics retain >=3:1 contrast");
        const alpha = 127 / 255;
        for (const channel of ["r", "g", "b"])
            fuzzyCompare(centre[channel], tokens.foreground[channel] * alpha + surface[channel] * (1 - alpha), 1.1 / 255,
                         "source 50% alpha is preserved: " + channel);
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
}
