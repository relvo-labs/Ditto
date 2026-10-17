pragma ComponentBehavior: Bound
import QtQuick

/// Replaceable candidates pending owner choice (D-48). No character assets.
Item {
    id: symbol
    required property var tokens
    property string variant: "neutral"
    implicitWidth: 32
    implicitHeight: 32

    Rectangle {
        anchors.centerIn: parent
        width: 28
        height: symbol.variant === "portrait" ? 30 : 23
        radius: symbol.variant === "portrait" ? 9 : 6
        color: symbol.tokens.surfaceStrong
        border.color: symbol.tokens.foregroundMuted
        border.width: 1
        Row {
            anchors.centerIn: parent
            spacing: symbol.variant === "portrait" ? 7 : 4
            Repeater {
                model: symbol.variant === "portrait" ? 2 : 3
                Rectangle {
                    width: 3
                    height: symbol.variant === "portrait" ? 6 : 3
                    radius: 1.5
                    color: symbol.tokens.foreground
                }
            }
        }
    }
}
