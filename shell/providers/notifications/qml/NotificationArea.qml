import QtQuick
import Quickshell
import Quickshell.Wayland

/// `ui.notifications`: the notification area. Notifications are Core's
/// (`notification_posted` / `notification_closed` events, `desktop.notifications.*`);
/// which ones are shown, merged or silenced is the policy service's decision
/// in hostd, not this surface's. When the policy service is unavailable,
/// notifications are still shown and the area says the rules are not applied.
Scope {
    id: provider

    property var client: null
    property var tokens: null
    property var config: ({})
    property var screen: null
    property string slotName: ""
    property string entryId: ""
    property bool shown: false

    readonly property string reservedEdge: "none"
    property bool ready: false
    readonly property int limit: config && config.max_visible ? config.max_visible : 3

    readonly property var visibleNotifications: {
        if (!client) {
            return [];
        }
        return client.notifications.filter(item => item.decision !== "silence").slice(0, limit);
    }
    readonly property bool policyUnavailable: !!client && ((client.policyStatus && client.policyStatus.available === false)
        || client.notifications.some(item => item.policy_unavailable))

    /// The notice shown when the policy service is unavailable, empty when
    /// it is not shown (read by the Shell's `services` control line).
    readonly property string policyNotice: policyUnavailable && shown ? policyText.text : ""

    function healthy() {
        return ready && client !== null && tokens !== null;
    }

    function release() {
        shown = false;
    }

    function t(source) {
        return client ? client.t(source) : source;
    }

    Component.onCompleted: ready = true

    PanelWindow {
        id: surface

        // No surface at all while there is nothing to show.
        visible: provider.shown && (provider.visibleNotifications.length > 0 || provider.policyUnavailable)
        anchors { top: true; right: true }
        margins { top: 6; right: 8 }
        exclusionMode: ExclusionMode.Normal
        exclusiveZone: 0
        implicitWidth: 340
        implicitHeight: stack.implicitHeight
        color: "transparent"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "ditto-notifications"

        Column {
            id: stack
            width: parent.width
            spacing: provider.tokens.space

            Rectangle {
                visible: provider.policyUnavailable
                width: parent.width
                height: policyText.implicitHeight + provider.tokens.space * 2
                radius: provider.tokens.radiusSmall
                color: provider.tokens.surfaceStrong
                border.color: provider.tokens.warning
                border.width: 1
                Text {
                    id: policyText
                    anchors.fill: parent
                    anchors.margins: provider.tokens.space
                    wrapMode: Text.WordWrap
                    color: provider.tokens.warning
                    font.pixelSize: provider.tokens.fontSmall
                    text: provider.t(qsTr("通知規則暫不可用，通知會全部顯示。"))
                }
            }

            Repeater {
                model: provider.visibleNotifications

                Rectangle {
                    required property var modelData
                    width: stack.width
                    height: body.implicitHeight + provider.tokens.spaceWide
                    radius: provider.tokens.radiusMedium
                    color: provider.tokens.surfaceStrong
                    border.color: modelData.urgency === "critical" ? provider.tokens.danger : provider.tokens.border
                    border.width: 1
                    opacity: provider.tokens.surfaceOpacity
                    Accessible.role: Accessible.AlertMessage
                    Accessible.name: modelData.summary + " " + modelData.body

                    Column {
                        id: body
                        anchors.left: parent.left
                        anchors.right: dismiss.left
                        anchors.top: parent.top
                        anchors.margins: provider.tokens.space
                        spacing: 2

                        Text {
                            width: parent.width
                            elide: Text.ElideRight
                            color: provider.tokens.foregroundMuted
                            font.pixelSize: provider.tokens.fontSmall
                            text: modelData.app_name
                                + (modelData.merged_count > 1 ? provider.t(qsTr("（已合併 %1 則）")).arg(modelData.merged_count) : "")
                        }
                        Text {
                            width: parent.width
                            wrapMode: Text.WordWrap
                            color: provider.tokens.foreground
                            font.pixelSize: provider.tokens.fontBody
                            font.bold: true
                            text: modelData.summary
                        }
                        Text {
                            width: parent.width
                            visible: text.length > 0
                            wrapMode: Text.WordWrap
                            maximumLineCount: 4
                            elide: Text.ElideRight
                            color: provider.tokens.foreground
                            font.pixelSize: provider.tokens.fontSmall
                            text: modelData.body
                        }
                    }

                    Text {
                        id: dismiss
                        anchors.top: parent.top
                        anchors.right: parent.right
                        anchors.margins: provider.tokens.space
                        visible: provider.client.capabilityAvailable("desktop.notifications.dismiss")
                        text: "✕"
                        color: provider.tokens.foregroundMuted
                        font.pixelSize: provider.tokens.fontBody
                        Accessible.role: Accessible.Button
                        Accessible.name: provider.t(qsTr("關閉通知"))
                        MouseArea {
                            anchors.fill: parent
                            anchors.margins: -6
                            onClicked: provider.client.dismissNotification(modelData.id)
                        }
                    }
                }
            }
        }
    }
}
