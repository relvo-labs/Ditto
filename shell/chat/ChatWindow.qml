import QtQuick
import Quickshell

/// The full conversation window. Closing it only hides it: a running turn
/// keeps going in Core and only 「停止」 cancels it.
FloatingWindow {
    id: window

    required property var client
    required property var tokens
    required property var conversation
    /// The Shell's RpcCounter: marks the first frame this surface shows
    /// (NFR-02: input → first visible frame).
    property var counter: null
    property bool assistantPresentation: false
    property bool framed: false
    Connections {
        target: body.Window.window
        function onFrameSwapped() {
            if (!window.framed && window.counter) {
                window.framed = true;
                window.counter.mark("chat.frame");
            }
        }
    }
    signal closeRequested()
    signal collapseRequested()
    signal settingsRequested()

    title: client.t(qsTr("Ditto 對話"))
    implicitWidth: 560
    implicitHeight: 680
    minimumSize: Qt.size(420, 420)
    color: assistantPresentation ? tokens.surface : tokens.background
    visible: true
    onClosed: window.closeRequested()

    /// The control with keyboard focus, for the Shell's `focus` line.
    readonly property Item focusedItem: body.Window.activeFocusItem

    function requestFocus() {
        body.focusInput();
    }

    ChatBody {
        id: body
        anchors.fill: parent
        focus: true
        client: window.client
        tokens: window.tokens
        conversation: window.conversation
        onCloseRequested: window.closeRequested()
        onCollapseRequested: window.collapseRequested()
        onSettingsRequested: window.settingsRequested()
        Component.onCompleted: focusInput()
    }
}
