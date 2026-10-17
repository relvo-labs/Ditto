import QtQuick

/// A labelled button, never a pretend input field. State is a projection of
/// the shared conversation; no subscription, timer or context acquisition here.
Rectangle {
    id: entry
    required property var tokens
    required property var conversation
    required property var client
    property string symbolVariant: "neutral"
    signal activated()
    implicitWidth: Math.max(218, label.implicitWidth + 84)
    implicitHeight: Math.max(54, label.implicitHeight + status.implicitHeight + 12)
    radius: height / 2
    color: area.containsMouse ? tokens.surfaceStrong : tokens.surface
    border.color: activeFocus ? tokens.focus : tokens.border
    border.width: activeFocus ? 2 : 1
    activeFocusOnTab: true
    Accessible.role: Accessible.Button
    Accessible.name: client.t(qsTr("開啟助理對話"))
    Accessible.description: status.text
    Accessible.onPressAction: entry.activated()
    Keys.onReturnPressed: entry.activated()
    Keys.onEnterPressed: entry.activated()
    Keys.onSpacePressed: entry.activated()

    AssistantSymbol {
        x: 12
        anchors.verticalCenter: parent.verticalCenter
        tokens: entry.tokens
        variant: entry.symbolVariant
    }
    Column {
        x: 54
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width - x - 16
        Text {
            id: label
            text: entry.client.t(qsTr("助理"))
            color: entry.tokens.foreground
            font.pixelSize: entry.tokens.fontBody
            font.weight: Font.DemiBold
        }
        Text {
            id: status
            width: parent.width
            text: entry.conversation.stateText + (entry.conversation.transportText ? " · " + entry.conversation.transportText : "")
            color: entry.tokens.foregroundMuted
            font.pixelSize: entry.tokens.fontSmall
            elide: Text.ElideRight
        }
    }
    MouseArea {
        id: area
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        // Same rounded shape as the surface input region.
        containmentMask: QtObject {
            function contains(point: point): bool {
                const r = entry.height / 2;
                const x = Math.max(r, Math.min(entry.width - r, point.x));
                return Math.pow(point.x - x, 2) + Math.pow(point.y - r, 2) <= r * r;
            }
        }
        onClicked: entry.activated()
    }
}
