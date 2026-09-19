import QtQuick
import Quickshell
import "../../jelly"

/// The one dock provider G0 ships. A second provider is what makes the seam
/// real, and that belongs to G1: building it now would fix the contract before
/// it is settled.
PanelWindow {
    id: dock

    required property var tokens
    required property var client

    anchors { bottom: true }
    implicitWidth: Math.max(220, entries.implicitWidth + tokens.spaceSection * 2)
    implicitHeight: 56
    exclusiveZone: 56
    color: "transparent"
    focusable: true

    Surface {
        anchors.fill: parent
        anchors.margins: tokens.space
        tokens: dock.tokens

        Row {
            id: entries
            anchors.centerIn: parent
            spacing: dock.tokens.space

            Repeater {
                model: dock.client.windows

                Rectangle {
                    required property var modelData
                    width: 150
                    height: 34
                    radius: dock.tokens.radiusSmall
                    color: modelData.focused ? dock.tokens.surfaceStrong : "transparent"
                    border.color: dock.tokens.border
                    border.width: 1
                    activeFocusOnTab: true

                    Row {
                        anchors.fill: parent
                        anchors.margins: dock.tokens.space
                        spacing: dock.tokens.spaceTight

                        Text {
                            width: parent.width - closeButton.width - dock.tokens.spaceTight
                            elide: Text.ElideRight
                            color: dock.tokens.foreground
                            font.pixelSize: dock.tokens.fontSmall
                            text: (modelData.focused ? "▸ " : "") + modelData.app_id
                        }

                        Text {
                            id: closeButton
                            // An action the compositor cannot perform is not
                            // shown as a button that would only fail.
                            visible: dock.client.capabilityAvailable("desktop.windows.close_request")
                            color: dock.tokens.foregroundMuted
                            font.pixelSize: dock.tokens.fontSmall
                            text: "✕"

                            MouseArea {
                                anchors.fill: parent
                                onClicked: dock.client.closeWindow(modelData.id)
                            }
                        }
                    }

                    Rectangle {
                        anchors.fill: parent
                        anchors.margins: -2
                        radius: parent.radius + 2
                        color: "transparent"
                        border.color: dock.tokens.foreground
                        border.width: parent.activeFocus ? 2 : 0
                    }

                    Keys.onReturnPressed: dock.client.focusWindow(modelData.id)
                    Keys.onSpacePressed: dock.client.focusWindow(modelData.id)
                    Keys.onDeletePressed: dock.client.closeWindow(modelData.id)

                    MouseArea {
                        anchors.fill: parent
                        z: -1
                        onClicked: dock.client.focusWindow(modelData.id)
                    }
                }
            }

            Text {
                visible: dock.client.windows.length === 0
                color: dock.tokens.foregroundMuted
                font.pixelSize: dock.tokens.fontSmall
                text: dock.client.online ? "目前沒有執行中的視窗" : dock.client.status
            }
        }
    }
}
