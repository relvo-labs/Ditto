import QtQuick

/// A short status label; the text carries the meaning, the colour repeats it.
Rectangle {
    id: badge

    required property var tokens
    property string text: ""
    /// neutral | good | warn | bad | info
    property string tone: "neutral"

    implicitWidth: label.implicitWidth + tokens.space * 2
    implicitHeight: label.implicitHeight + 4
    radius: height / 2
    color: tone === "good" ? tokens.success
        : tone === "warn" ? tokens.warning
        : tone === "bad" ? tokens.danger
        : tone === "info" ? tokens.accent
        : tokens.surfaceStrong
    border.color: tokens.border
    border.width: tone === "neutral" ? 1 : 0

    Text {
        id: label
        anchors.centerIn: parent
        text: badge.text
        color: badge.tone === "neutral" ? badge.tokens.foreground
            : badge.tone === "info" ? badge.tokens.accentForeground : badge.tokens.statusForeground
        font.pixelSize: badge.tokens.fontSmall
    }
}
