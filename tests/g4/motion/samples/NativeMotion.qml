import QtQuick
import QtTest
import DittoStub
import "../../visual/.staged/assistant/shell/jelly" as Jelly
import "../../visual/.staged/assistant/shell/chat" as Chat

// Live QML sampling, never interpolated/generated image frames. The runner
// redirects the ignored output symlink to an outside evidence directory.
TestCase {
    id: sample
    name: "NativeMotionRecording"
    width: 1280; height: 800
    visible: true
    when: windowShown
    readonly property string outDir: Qt.resolvedUrl("../../visual/.staged/motion-recording/frames/").toString().replace("file://", "")
    property string action: "First presentation"
    property string mode: "normal"
    property bool chatOpen: false
    property var dock: null
    property var surface: null
    property var entry: null
    property var chat: null
    property int activations: 0
    property int nextFrame: 0
    FrameAnimation { id: frameClock; running: true }
    Item {
        id: desktop
        width: 1280; height: 800
        Jelly.Backdrop { anchors.fill: parent; tokens: tokens }
        Item { id: layer; anchors.fill: parent }
        MouseArea { id: neutral; x: 24; y: 400; width: 500; height: 180; hoverEnabled: true }
        Column {
            x: 24; y: 20; spacing: 12
            Text { text: "Native QML motion candidate · DEVELOPMENT FIXTURES"; font.pixelSize: 22; color: tokens.foreground }
            Text { text: "Offscreen / software · layer-shell stubs · no Core / model / Wayfire"; font.pixelSize: 16; color: tokens.foregroundMuted }
            Text { text: "Mode: " + sample.mode + " · " + sample.action; font.pixelSize: 17; color: tokens.foreground }
            Text {
                text: "Actual glyph scale: " + (sample.entry ? sample.entry.children[0].scale.toFixed(3) : "—")
                    + "    opacity: " + (sample.entry ? sample.entry.children[0].opacity.toFixed(3) : "—")
                    + "\nWorking cue running: " + (sample.entry ? sample.entry.workingCueRunning : false)
                    + "    chat present: " + !!sample.chat
                    + "\nShared fixture turn: " + (conversation.turn ? conversation.turn.state : "idle")
                    + "\nEntry activations: " + sample.activations + "    fixture app commands: " + client.calls.length
                font.pixelSize: 16; lineHeight: 1.4; color: tokens.foregroundMuted
            }
            Text { text: "Candidate timings at 1× · sampled live, not frame-time/NFR evidence"; font.pixelSize: 14; color: tokens.foregroundMuted }
        }
    }
    Jelly.Tokens { id: tokens; appearance: ({ theme: "soft-jelly-light" }) }
    QtObject {
        id: client
        property bool online: true
        property var packages: []
        property var windows: []
        property var calls: []
        signal changeUpdated(var change)
        signal disconnected()
        function t(text) { return text; }
        function key(text, args) { return text; }
        function capabilityAvailable(name) { return false; }
        function capability(method, args, ok, fail) {
            if (method === "desktop.launcher.list_apps") ok({ apps: [
                { app_id: "fixture-files", name: "Fixture Files", icon: "" },
                { app_id: "fixture-editor", name: "Fixture Editor", icon: "" }
            ] });
        }
        function launchApp(id, ok, fail) { calls = calls.concat(["launch " + id]); }
        function focusWindow(id) { calls = calls.concat(["focus " + id]); }
    }
    Chat.ConversationState { id: conversation; client: client }
    function mount(path, props) {
        const component = Qt.createComponent(Qt.resolvedUrl("../../visual/.staged/" + path));
        compare(component.status, Component.Ready, component.errorString());
        const incubator = component.incubateObject(sample, props);
        incubator.forceCompletion();
        verify(!!incubator.object, component.errorString());
        return incubator.object;
    }
    function tile() { return findChild(layer, "dockTile_fixture-files"); }
    function content() { return chat ? findChild(chat.contentItem, "chatPresentationContent") : null; }
    function closeChat() {
        if (chat) chat.destroy();
        chat = null;
        chatOpen = false;
    }
    function openChat() {
        if (chat) { chat.requestFocus(); return; }
        chat = mount("assistant/shell/chat/ChatPanel.qml", { tokens: tokens, client: client,
            conversation: conversation, screen: { width: 1280, height: 800 },
            entryRect: { x: 1030, y: 714, width: 218, height: 54 } });
        chat.closeRequested.connect(closeChat);
        chatOpen = true;
    }
    function turn(state) { conversation.turn = { turn_id: "fixture-motion-turn", state: state }; }
    function stoppedCue() { compare(entry.workingCueRunning, false); compare(entry.workLevel, 1); }
    function prefs(name, values) {
        mode = name;
        tokens.appearance = Object.assign({ theme: "soft-jelly-light" }, values);
    }
    function observed() {
        return { mode: mode, action: action, entry_visible: entry.visible, chat_present: !!chat,
            symbol_scale: entry.children[0].scale, symbol_opacity: entry.children[0].opacity,
            feedback_running: entry.feedbackRunning, working_cue_running: entry.workingCueRunning,
            dock_reveal: dock.reveal, dock_icon_scale: findChild(tile(), "dockIconFallback").scale,
            chat_opacity: content() ? content().opacity : null,
            turn: conversation.turn ? conversation.turn.state : null,
            state_text: entry.statusText, draft: conversation.draft, activations: activations };
    }
    function test_record() {
        StubDesktop.layer = layer;
        StubDesktop.screenWidth = 1280; StubDesktop.screenHeight = 800;
        conversation.wanted = true;
        conversation.settings = { enabled: true };
        conversation.provider = { available: true, authenticated: true };
        conversation.sessionId = "fixture-motion-session";
        conversation.draft = "未送出的草稿 · fixture draft";
        console.log("MOTION_PROVENANCE " + JSON.stringify({ graphics_api: desktop.GraphicsInfo.api,
            renderer: desktop.GraphicsInfo.api === GraphicsInfo.Software ? "software" : "graphics-api-" + desktop.GraphicsInfo.api,
            os: Qt.platform.os, fixture: true, layer_shell: "QML stubs", time_scale: 1,
            viewport: [1280, 800], params: { feedback_ms: tokens.motionFeedback, present_ms: tokens.motionPresent } }));
        surface = mount("assistant/shell/assistant/AssistantSurface.qml", {
            tokens: tokens, conversation: conversation, client: client,
            screen: { width: 1280, height: 800 }, expanded: Qt.binding(() => sample.chatOpen) });
        entry = surface.contentItem.children.find(item => typeof item.symbolVariant === "string");
        verify(!!entry);
        surface.activated.connect(function () { activations++; if (chat) closeChat(); else openChat(); });
        dock = mount("providers/DockPill.qml", { tokens: tokens, client: client,
            config: { pinned: ["fixture-files", "fixture-editor"] }, shown: false });
        dock.shown = true;
        verify(waitForRendering(desktop));
        const steps = [
            { at: 600, label: "Dock hover", run: () => mouseMove(tile(), 26, 26) },
            { at: 1000, label: "Dock press", run: () => mousePress(tile(), 26, 26) },
            { at: 1120, label: "Release / reverse", run: () => mouseRelease(tile(), 26, 26) },
            { at: 1170, label: "Press during return", run: () => mousePress(tile(), 26, 26) },
            { at: 1290, label: "Release; no optimistic success", run: () => { mouseRelease(tile(), 26, 26); compare(tile().confirmedScale, 1); compare(client.calls.length, 2); } },
            { at: 1700, label: "Fixture focused-window readback", run: () => { client.windows = [{ id: "fixture-window", app_id: "fixture-files", focused: true }]; } },
            { at: 2100, label: "Assistant hover", run: () => mouseMove(entry, 30, 27) },
            { at: 2400, label: "Assistant press", run: () => mousePress(entry, 30, 27) },
            { at: 2520, label: "Open compact; focus is immediate", run: () => { mouseRelease(entry, 30, 27); verify(!!chat); } },
            { at: 2920, label: "Close instantly", run: () => { entry.forceActiveFocus(); keyClick(Qt.Key_Return); verify(!chat); } },
            { at: 3160, label: "Open again", run: () => { keyClick(Qt.Key_Return); verify(!!chat); } },
            { at: 3280, label: "Close during presentation", run: () => { entry.forceActiveFocus(); keyClick(Qt.Key_Return); verify(!chat); } },
            { at: 3460, label: "Latest open wins", run: () => { keyClick(Qt.Key_Return); verify(!!chat); } },
            { at: 4100, label: "Authoritative fixture: running", run: () => { turn("running"); verify(entry.workingCueRunning); } },
            { at: 5500, label: "Cancelling: working cue stops now", run: () => { turn("cancelling"); stoppedCue(); } },
            { at: 6200, label: "Fixture running again", run: () => turn("running") },
            { at: 6900, label: "Terminal succeeded: cue stops", run: () => { turn("succeeded"); stoppedCue(); } },
            { at: 7450, label: "Partial: retain truthful text", run: () => { turn("partial"); stoppedCue(); } },
            { at: 7950, label: "Unknown: no success animation", run: () => { turn("unknown"); stoppedCue(); } },
            { at: 8400, label: "Running before hide", run: () => turn("running") },
            { at: 8700, label: "Hide: cue off; task still running", run: () => { surface.shown = false; stoppedCue(); compare(conversation.turn.state, "running"); } },
            { at: 9200, label: "Show same projection; prepare preference reversal", run: () => { surface.shown = true; closeChat(); dock.shown = false; } },
            { at: 9650, label: "Normal finite transitions start", run: () => { dock.shown = true; openChat(); } },
            { at: 9720, label: "Mid-transition reduced motion: settle now", run: () => {
                verify(dock.revealAnimation.running || content().opacity < 1);
                prefs("reduced motion", { reduced_motion: true });
                compare(dock.reveal, 1); compare(content().opacity, 1); stoppedCue();
            } },
            { at: 10400, label: "Reduced motion: same close action", run: () => { chat.closeRequested(); verify(!chat); } },
            { at: 10800, label: "Reduced motion: same open / draft", run: () => { openChat(); compare(conversation.draft, "未送出的草稿 · fixture draft"); } },
            { at: 11400, label: "Low power: same working text, static glyph", run: () => { prefs("low power", { low_power_style: true }); stoppedCue(); } },
            { at: 12500, label: "Normal: working cue resumes from projection", run: () => { prefs("normal", {}); verify(entry.workingCueRunning); } },
            { at: 13600, label: "Reduced transparency: opaque surface, local motion", run: () => { prefs("reduced transparency", { reduced_transparency: true }); verify(entry.workingCueRunning); } },
            { at: 14600, label: "Hide during work: cleanup", run: () => { surface.shown = false; closeChat(); stoppedCue(); compare(conversation.turn.state, "running"); } },
            { at: 15100, label: "Show unknown terminal; no replay", run: () => { turn("unknown"); surface.shown = true; stoppedCue(); compare(client.calls.length, 2); } }
        ];
        let next = 0;
        const start = Date.now();
        while (Date.now() - start < 16000) {
            while (next < steps.length && Date.now() - start >= steps[next].at) {
                action = steps[next].label;
                steps[next].run();
                console.log("MOTION_EVENT " + JSON.stringify({ elapsed_wall_ms: Date.now() - start, index: next, observed: observed() }));
                next++;
            }
            const wallStart = Date.now();
            const path = outDir + String(nextFrame).padStart(5, "0") + ".png";
            const image = grabImage(desktop);
            verify(image.width > 0 && image.height > 0);
            image.save(path); // QtTest save() returns void; Python verifies each file.
            console.log("MOTION_FRAME " + JSON.stringify({ frame: nextFrame++, file: path,
                sample_wall_start_ms: wallStart, sample_wall_end_ms: Date.now(),
                animation_elapsed_s: frameClock.elapsedTime, animation_frame: frameClock.currentFrame,
                observed: observed() }));
            wait(25);
        }
        compare(next, steps.length);
        compare(conversation.draft, "未送出的草稿 · fixture draft");
        closeChat(); surface.destroy(); surface = null; dock.release(); dock.destroy(); dock = null;
        wait(20);
    }
}
