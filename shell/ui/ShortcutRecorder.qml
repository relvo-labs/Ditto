pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Wayland

/// Window-owned native recorder. No persistent state, text-input fallback or
/// automatic re-grab. safetyReady is false until the host's compositor escape
/// policy is verified; this checkpoint does not invent a production grant.
FloatingWindow {
    id: recorder
    required property var client
    required property var tokens
    property string actionTitle: ""
    property var reservedBindings: []
    property int activationKey: 0
    property bool safetyReady: false
    readonly property string phase: capture.phase
    readonly property bool inhibited: inhibitor.active
    readonly property bool inputFocus: keyArea.activeFocus
    signal captured(string chord)
    signal reservedPressed(string chord)
    signal finished(string reason)
    title: client.t(qsTr("設定快捷鍵"))
    implicitWidth: 520
    implicitHeight: Math.max(300, body.implicitHeight + tokens.spaceWide * 2)
    minimumSize: Qt.size(360, implicitHeight)
    visible: true
    color: tokens.background

    function start() {
        keyArea.forceActiveFocus();
        capture.begin(activationKey);
        if (!safetyReady) { capture.stop("unavailable"); return; }
        inhibitor.enabled = true;
    }
    function cancel() { if (capture.requested) capture.stop("cancelled"); else finished("cancelled"); }
    Component.onCompleted: start()
    Component.onDestruction: { inhibitor.enabled = false; }
    onClosed: capture.stop("closed")
    onVisibleChanged: if (!visible && capture.requested) capture.stop("hidden")

    ShortcutCaptureState {
        id: capture
        reserved: recorder.reservedBindings.map(binding => binding.chord)
        onCaptured: chord => { inhibitor.enabled = false; recorder.captured(chord); recorder.finished("captured"); }
        onReservedPressed: chord => { inhibitor.enabled = false; recorder.reservedPressed(chord); recorder.finished("reserved"); }
        onStopped: reason => {
            // The pinned inhibitor emits activeChanged from inside its native
            // focus/deactivation callback. Do not delete its protocol object
            // reentrantly. Capture is already stopped synchronously above.
            Qt.callLater(function() {
                if (!recorder || !inhibitor) return; // window may have been destroyed
                inhibitor.enabled = false;
                if (reason !== "unavailable") recorder.finished(reason);
            });
        }
    }
    ShortcutInhibitor {
        id: inhibitor
        window: recorder
        enabled: false
        onActiveChanged: {
            if (active) capture.grant();
            else if (capture.listening) capture.stop("focus-lost");
        }
        onCancelled: capture.stop("compositor-cancelled")
    }
    // Grant timeout is UI recovery, never the compositor escape guarantee.
    Timer {
        interval: 1500
        running: capture.phase === "requesting"
        onTriggered: capture.stop("unavailable")
    }
    Connections {
        target: recorder.client
        ignoreUnknownSignals: true
        function onDisconnected() { capture.stop("disconnected"); }
    }
    Item {
        id: keyArea
        anchors.fill: parent
        focus: true
        readonly property bool windowActive: Window.active
        onWindowActiveChanged: if (!windowActive && capture.listening) capture.stop("focus-lost")
        Keys.onPressed: event => {
            if (event.key === Qt.Key_Escape && (!capture.listening || event.modifiers === Qt.NoModifier)) recorder.cancel();
            else capture.press(event.nativeScanCode, event.isAutoRepeat, event.modifiers);
            event.accepted = true;
        }
        Keys.onReleased: event => { capture.release(event.nativeScanCode, event.isAutoRepeat, event.modifiers); event.accepted = true; }
        Column {
            id: body
            anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
            anchors.margins: recorder.tokens.spaceWide
            spacing: recorder.tokens.spaceWide
            Text {
                width: parent.width; wrapMode: Text.WordWrap
                text: recorder.actionTitle
                color: recorder.tokens.appInk; font.pixelSize: recorder.tokens.appFontTitle; font.bold: true
            }
            Text {
                objectName: "recordingStatus"
                width: parent.width; wrapMode: Text.WordWrap
                text: capture.phase === "requesting" ? recorder.client.t(qsTr("正在等待系統允許錄製…"))
                    : capture.phase === "unavailable" ? recorder.client.t(qsTr("目前無法安全錄製。尚未確認系統的緊急退出設定，或系統未允許暫停快捷鍵。請關閉後再試。"))
                    : capture.phase === "arming" ? recorder.client.t(qsTr("請先放開啟動錄製的按鍵。"))
                    : capture.phase === "cancelled" ? recorder.client.t(qsTr("錄製已取消，原按鍵未更改。"))
                    : capture.phase === "captured" ? recorder.client.t(qsTr("已讀取按鍵，尚未套用。"))
                    : capture.phase === "releasing" ? recorder.client.t(qsTr("請放開所有按鍵。"))
                    : recorder.client.t(qsTr("請按下組合鍵。Esc 取消，原按鍵不會更改。"))
                color: capture.phase === "unavailable" ? recorder.tokens.appWarning : recorder.tokens.appInk
                font.pixelSize: recorder.tokens.appFontBody
                Accessible.role: Accessible.AlertMessage
                Accessible.name: text
            }
            Flow {
                width: parent.width; spacing: recorder.tokens.space
                Repeater {
                    model: capture.candidate ? capture.candidate.split("+") : capture.modifiers
                    Rectangle {
                        required property string modelData
                        width: keyLabel.implicitWidth + 24; height: 42; radius: 10
                        color: recorder.tokens.surfaceStrong; border.color: recorder.tokens.border
                        Text {
                            id: keyLabel; anchors.centerIn: parent
                            text: parent.modelData === "Space" ? recorder.client.t(qsTr("空白鍵")) : parent.modelData
                            color: recorder.tokens.appInk; font.pixelSize: recorder.tokens.appFontBody
                        }
                    }
                }
            }
            Text {
                width: parent.width; wrapMode: Text.WordWrap
                text: capture.issue === "release-first" ? recorder.client.t(qsTr("請先放開所有按鍵，再重新按組合。"))
                    : capture.issue === "unsupported" ? recorder.client.t(qsTr("這個按鍵目前不支援。請放開後換一組；不支援 AltGr、多媒體鍵或多段組合。"))
                    : capture.issue === "multiple" ? recorder.client.t(qsTr("一次只能設定一個主鍵。請放開所有按鍵後再試。"))
                    : recorder.client.t(qsTr("可使用 Ctrl、Alt、Shift、Super，加上英數、F1–F12 或導覽鍵。"))
                color: capture.issue ? recorder.tokens.appWarning : recorder.tokens.appInkMuted
                font.pixelSize: recorder.tokens.appFontCaption
            }
            Button {
                tokens: recorder.tokens
                text: recorder.client.t(qsTr("取消錄製"))
                onClicked: recorder.cancel()
            }
        }
    }
}
