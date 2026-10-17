import QtQuick
import Quickshell
import Quickshell.Wayland

/// The compact chat beside the character (AVA-03). It is its own surface,
/// so it takes clicks only inside its own rectangle; the character's
/// transparent area keeps passing clicks through. Escape folds it away
/// without stopping anything.
PanelWindow {
    id: panel

    required property var client
    required property var tokens
    required property var conversation
    /// The Shell's RpcCounter: marks the first frame this surface shows
    /// (NFR-02: input → first visible frame).
    property var counter: null
    property bool framed: false
    Connections {
        target: body.Window.window
        function onFrameSwapped() {
            if (!panel.framed && panel.counter) {
                panel.framed = true;
                panel.counter.mark("chat.frame");
            }
        }
    }
    /// The character's corner (`bottom_right`, …) and the space it takes.
    property string corner: "bottom_right"
    property int avatarHeight: 250
    /// Actual entry rectangle in output-local coordinates; null is the exact
    /// legacy layout. The output/corner selection remains the Shell's.
    property var entryRect: null
    readonly property real entryPanelTop: entryRect ? entryRect.y + entryRect.height + 8 : 0
    readonly property real entryPanelBottom: entryRect && screen ? screen.height - entryRect.y + 8 : 0
    signal closeRequested()
    signal expandRequested()
    signal settingsRequested()

    anchors {
        top: corner.indexOf("top") === 0
        bottom: corner.indexOf("bottom") === 0
        left: corner.indexOf("left") > 0
        right: corner.indexOf("right") > 0
    }
    // Next to the character, clear of the panel and dock.
    margins {
        top: entryRect ? entryPanelTop : 64 + avatarHeight + 8
        bottom: entryRect && screen ? entryPanelBottom : 64 + avatarHeight + 8
        left: entryRect ? Math.min(entryRect.x, (screen ? screen.width : 900) - panel.implicitWidth - 8) : 32
        right: entryRect && screen ? Math.max(8, screen.width - entryRect.x - entryRect.width) : 32
    }
    implicitWidth: entryRect && screen ? Math.min(400, screen.width - 16) : 400
    implicitHeight: entryRect && screen
        ? Math.max(1, Math.min(520, corner.indexOf("top") === 0
            ? screen.height - entryPanelTop - 8 : screen.height - entryPanelBottom - 8))
        : Math.min(520, (screen ? screen.height : 900) - 64 * 2 - avatarHeight - 16)
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    aboveWindows: true
    WlrLayershell.namespace: "ditto-chat-panel"
    /// Opening (or asking for the chat again by shortcut) takes the keyboard
    /// for a moment, so typing goes into the message field without a click;
    /// then focus is on-demand again and other windows can take it back.
    property bool grab: true
    WlrLayershell.keyboardFocus: grab ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.OnDemand

    function requestFocus() {
        grab = true;
        release.restart();
        body.focusInput();
    }

    Timer {
        id: release
        interval: 300
        running: true
        onTriggered: panel.grab = false
    }

    /// The control with keyboard focus, for the Shell's `focus` line.
    readonly property Item focusedItem: body.Window.activeFocusItem

    Rectangle {
        anchors.fill: parent
        radius: panel.tokens.radiusLarge
        color: panel.entryRect ? panel.tokens.surface : panel.tokens.background
        border.color: panel.tokens.border
        border.width: 1

        ChatBody {
            id: body
            anchors.fill: parent
            anchors.margins: 2
            focus: true
            compact: true
            client: panel.client
            tokens: panel.tokens
            conversation: panel.conversation
            onCloseRequested: panel.closeRequested()
            onExpandRequested: panel.expandRequested()
            onSettingsRequested: panel.settingsRequested()
            Component.onCompleted: focusInput()
        }
    }
}
