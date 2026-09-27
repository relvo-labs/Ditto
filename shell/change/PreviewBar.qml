import QtQuick
import Quickshell
import Quickshell.Wayland
import "../ui"

/// The try-it bar: a committed change waiting to be kept (a preview, or a
/// change with a timed revert such as turning reduced transparency off).
/// 「保留」 confirms it; 「取消」 or letting the countdown run out reverts it.
/// The countdown is Core's deadline: Core's timer reverts even if this
/// Shell dies, and the bar only says what Core reports.
Scope {
    id: bar

    property var client: null
    property var tokens: null

    readonly property var pending: {
        if (!client) {
            return null;
        }
        const list = Object.values(client.pendingConfirmations);
        list.sort((left, right) => left.created_at < right.created_at ? -1 : 1);
        return list.length > 0 ? list[0] : null;
    }
    property double now: Date.now()
    readonly property int secondsLeft: pending && pending.confirmation.deadline
        ? Math.max(0, Math.ceil((Date.parse(pending.confirmation.deadline) - now) / 1000)) : 0
    property string busy: ""
    property string notice: ""

    function t(source) {
        return client ? client.t(source) : source;
    }

    function keep() {
        if (!pending || busy.length > 0) {
            return;
        }
        busy = "keep";
        notice = "";
        client.confirmChange(pending.change_id, function (record) {
            bar.busy = "";
            client.notePending(record);
        }, function (error) {
            bar.busy = "";
            bar.notice = client.errorText(error);
        });
    }

    function cancel() {
        if (!pending || busy.length > 0) {
            return;
        }
        busy = "cancel";
        notice = "";
        client.cancelChange(pending.change_id, function (record) {
            bar.busy = "";
            client.refreshPendingConfirmations();
        }, function (error) {
            bar.busy = "";
            bar.notice = client.errorText(error);
        });
    }

    /// A UI clock for the countdown text only; it runs while the bar exists.
    Timer {
        interval: 500
        repeat: true
        running: bar.pending !== null
        onTriggered: bar.now = Date.now()
    }

    PanelWindow {
        visible: bar.pending !== null && bar.tokens !== null
        anchors { top: true }
        margins { top: 44 }
        exclusionMode: ExclusionMode.Ignore
        implicitWidth: Math.max(520, row.implicitWidth + 32)
        implicitHeight: 56
        color: "transparent"
        focusable: true
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand
        WlrLayershell.namespace: "ditto-preview-bar"

        Rectangle {
            anchors.fill: parent
            radius: bar.tokens ? bar.tokens.radiusLarge : 12
            color: bar.tokens ? bar.tokens.surfaceStrong : "#242739"
            border.color: bar.tokens ? bar.tokens.accent : "#b9a4ff"
            border.width: 2
        }

        Row {
            id: row
            anchors.centerIn: parent
            spacing: bar.tokens ? bar.tokens.spaceWide : 16

            Column {
                anchors.verticalCenter: parent.verticalCenter
                spacing: 2

                Text {
                    // A ChangeSummary carries title_key; a full ChangeRecord its card.
                    text: bar.pending ? bar.t(qsTr("要保留這項變更嗎？")) + "  "
                        + bar.client.key(bar.pending.title_key || (bar.pending.card ? bar.pending.card.title_key : ""), {}) : ""
                    color: bar.tokens ? bar.tokens.foreground : "white"
                    font.pixelSize: bar.tokens ? bar.tokens.fontBody : 13
                    font.bold: true
                    Accessible.role: Accessible.AlertMessage
                    Accessible.name: text
                }

                Text {
                    text: bar.notice.length > 0 ? bar.notice
                        : bar.busy === "keep" ? bar.t(qsTr("正在保留…"))
                        : bar.busy === "cancel" ? bar.t(qsTr("正在回復…"))
                        : bar.secondsLeft > 0 ? bar.t(qsTr("%1 秒後自動回復")).arg(bar.secondsLeft)
                        : bar.t(qsTr("時間已到，正在等待自動回復"))
                    color: bar.notice.length > 0 ? bar.tokens.warning : bar.tokens.foregroundMuted
                    font.pixelSize: bar.tokens ? bar.tokens.fontSmall : 11
                }
            }

            Button {
                anchors.verticalCenter: parent.verticalCenter
                tokens: bar.tokens
                kind: "primary"
                text: bar.t(qsTr("保留"))
                enabled: bar.busy.length === 0 && bar.secondsLeft > 0
                onClicked: bar.keep()
            }

            Button {
                anchors.verticalCenter: parent.verticalCenter
                tokens: bar.tokens
                text: bar.t(qsTr("取消"))
                enabled: bar.busy.length === 0
                onClicked: bar.cancel()
            }
        }
    }
}
