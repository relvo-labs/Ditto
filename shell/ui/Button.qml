import QtQuick

/// A button of the Shell's own surfaces. Keyboard: Tab to reach, Enter or
/// Space to press; focus is drawn as a ring, not only as a colour change.
Rectangle {
    id: button

    required property var tokens
    property string text: ""
    /// primary | secondary | subtle | danger
    property string kind: "secondary"
    property string accessibleName: text
    signal clicked()

    implicitWidth: label.implicitWidth + tokens.spaceWide * 2
    implicitHeight: tokens.controlHeight
    radius: tokens.radiusSmall
    opacity: enabled ? 1.0 : 0.45
    color: kind === "primary" ? tokens.accent
        : kind === "danger" ? tokens.danger
        : kind === "subtle" ? (area.containsMouse ? tokens.surface : "transparent")
        : (area.containsMouse ? tokens.surface : tokens.surfaceStrong)
    border.color: kind === "subtle" ? "transparent" : tokens.border
    border.width: 1
    activeFocusOnTab: enabled
    Accessible.role: Accessible.Button
    Accessible.name: accessibleName
    Accessible.onPressAction: if (enabled) clicked()

    Keys.onReturnPressed: if (enabled) clicked()
    Keys.onEnterPressed: if (enabled) clicked()
    Keys.onSpacePressed: if (enabled) clicked()

    Text {
        id: label
        anchors.centerIn: parent
        text: button.text
        color: button.kind === "primary" ? button.tokens.accentForeground
            : button.kind === "danger" ? button.tokens.statusForeground : button.tokens.foreground
        font.pixelSize: button.tokens.fontBody

        // The `font_family` token, when the Profile sets one; the system
        // font otherwise.
        Binding on font.family {
            when: button.tokens.fontFamily.length > 0
            value: button.tokens.fontFamily
        }
    }

    Rectangle {
        anchors.fill: parent
        anchors.margins: -3
        radius: parent.radius + 3
        color: "transparent"
        border.color: button.tokens.focus
        border.width: button.activeFocus ? 2 : 0
    }

    MouseArea {
        id: area
        anchors.fill: parent
        hoverEnabled: true
        enabled: button.enabled
        cursorShape: Qt.PointingHandCursor
        onClicked: button.clicked()
    }
}
