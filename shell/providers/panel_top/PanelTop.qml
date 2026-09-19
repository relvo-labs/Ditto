import QtQuick
import Quickshell
import "../../jelly"

/// Top panel: workspaces, the focused window and the real state of the desktop
/// service. Nothing here polls; every value arrives with a snapshot or an event.
PanelWindow {
    id: panel

    required property var tokens
    required property var client

    anchors { top: true; left: true; right: true }
    implicitHeight: 34
    exclusiveZone: 34
    color: "transparent"
    focusable: true

    Surface {
        anchors.fill: parent
        anchors.margins: 2
        tokens: panel.tokens
        radius: panel.tokens.radiusSmall

        Row {
            anchors.left: parent.left
            anchors.leftMargin: panel.tokens.spaceWide
            anchors.verticalCenter: parent.verticalCenter
            spacing: panel.tokens.space

            Repeater {
                model: panel.client.workspaces

                Rectangle {
                    required property var modelData
                    width: label.implicitWidth + panel.tokens.spaceWide
                    height: 22
                    radius: panel.tokens.radiusSmall
                    color: modelData.active ? panel.tokens.accent : "transparent"
                    border.color: panel.tokens.border
                    border.width: modelData.active ? 0 : 1
                    activeFocusOnTab: true

                    Text {
                        id: label
                        anchors.centerIn: parent
                        text: modelData.name
                        color: modelData.active ? "#1a1626" : panel.tokens.foreground
                        font.pixelSize: panel.tokens.fontSmall
                    }

                    // Focus is visible on its own, not only by colour.
                    Rectangle {
                        anchors.fill: parent
                        anchors.margins: -2
                        radius: parent.radius + 2
                        color: "transparent"
                        border.color: panel.tokens.foreground
                        border.width: parent.activeFocus ? 2 : 0
                    }

                    Keys.onReturnPressed: panel.client.activateWorkspace(modelData.id)
                    Keys.onSpacePressed: panel.client.activateWorkspace(modelData.id)

                    MouseArea {
                        anchors.fill: parent
                        enabled: panel.client.capabilityAvailable("desktop.workspaces.activate")
                        onClicked: panel.client.activateWorkspace(modelData.id)
                    }
                }
            }
        }

        Text {
            anchors.centerIn: parent
            width: parent.width * 0.4
            elide: Text.ElideRight
            horizontalAlignment: Text.AlignHCenter
            color: panel.tokens.foreground
            font.pixelSize: panel.tokens.fontBody
            text: {
                const focused = panel.client.windows.find(item => item.focused);
                return focused ? focused.title : "沒有作用中的視窗";
            }
        }

        Text {
            anchors.right: parent.right
            anchors.rightMargin: panel.tokens.spaceWide
            anchors.verticalCenter: parent.verticalCenter
            color: panel.client.online ? panel.tokens.foregroundMuted : panel.tokens.warning
            font.pixelSize: panel.tokens.fontSmall
            text: panel.client.online
                ? panel.client.windows.length + " 個視窗"
                : panel.client.status
        }
    }
}
