pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import "../ui"

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

    /// #116 application style (Profile `ui_style`, light recipe); false
    /// keeps the existing window.
    readonly property bool jelly: tokens.uiCandidate === true

    title: client.t(qsTr("Ditto 對話"))
    implicitWidth: 560
    implicitHeight: jelly && screen && screen.height ? Math.max(420, Math.min(680, screen.height - tokens.uiWindowClearance)) : 680
    minimumSize: Qt.size(420, 420)
    color: jelly ? "transparent" : assistantPresentation ? tokens.surface : tokens.background
    visible: true
    onClosed: window.closeRequested()

    /// The control with keyboard focus, for the Shell's `focus` line.
    readonly property Item focusedItem: body.Window.activeFocusItem

    function requestFocus() {
        body.focusInput();
    }

    // ---- #116 candidate frame and its one title ----
    Loader {
        anchors.fill: parent
        active: window.jelly
        sourceComponent: JellySurface {
            tokens: window.tokens
            radius: window.tokens.uiRadiusWindow
            fill: window.tokens.uiJ3 && window.tokens.uiGloss ? window.tokens.uiCanvasLow : window.tokens.uiCanvas
            fillTop: window.tokens.uiGloss ? Qt.lighter(window.tokens.uiCanvas, 1.03) : window.tokens.uiCanvas
            raised: false
            iris: window.tokens.uiJ3
            bubbles: true
        }
    }
    Loader {
        id: header
        active: window.jelly
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        sourceComponent: WindowHeader {
            tokens: window.tokens
            hostWindow: window
            title: window.title
            minimizeText: window.client.t(qsTr("縮小視窗"))
            maximizeText: window.client.t(qsTr("放大視窗"))
            restoreText: window.client.t(qsTr("還原視窗大小"))
            closeText: window.client.t(qsTr("關閉對話視窗（對話會繼續）"))
            onCloseRequested: window.closeRequested()
        }
    }

    ChatBody {
        id: body
        anchors.fill: parent
        anchors.topMargin: window.jelly ? header.height : 0
        showTitle: !window.jelly
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
