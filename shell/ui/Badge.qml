import QtQuick

/// A short status label; the text carries the meaning, the colour repeats it.
/// With a #116 candidate style: a soft tinted chip with a leading dot in the
/// tone's (readable) ink, instead of a saturated fill.
Rectangle {
    id: badge

    required property var tokens
    property string text: ""
    /// neutral | good | warn | bad | info
    property string tone: "neutral"

    readonly property bool jelly: tokens.uiCandidate === true
    readonly property color jellyInk: tone === "good" ? tokens.uiSuccess
        : tone === "warn" ? tokens.uiWarning
        : tone === "bad" ? tokens.uiDanger
        : tone === "info" ? tokens.uiInfo : tokens.uiInkMuted

    implicitWidth: jelly ? label.implicitWidth + tokens.uiGap * 2 + 12 : label.implicitWidth + tokens.space * 2
    implicitHeight: jelly ? Math.max(22, label.implicitHeight + 6) : label.implicitHeight + 4
    radius: height / 2
    color: jelly ? (tone === "good" ? tokens.uiSuccessFill
            : tone === "warn" ? tokens.uiWarningFill
            : tone === "bad" ? tokens.uiDangerFill
            : tone === "info" ? tokens.uiInfoFill : tokens.uiTrack)
        : tone === "good" ? tokens.success
        : tone === "warn" ? tokens.warning
        : tone === "bad" ? tokens.danger
        : tone === "info" ? tokens.accent
        : tokens.surfaceStrong
    border.color: jelly ? "transparent" : tokens.border
    border.width: tone === "neutral" && !jelly ? 1 : 0

    Rectangle {
        visible: badge.jelly
        width: 6
        height: 6
        radius: 3
        x: badge.tokens.uiGap + 1
        anchors.verticalCenter: parent.verticalCenter
        color: badge.jellyInk
    }

    Text {
        id: label
        anchors.centerIn: parent
        anchors.horizontalCenterOffset: badge.jelly ? 6 : 0
        text: badge.text
        color: badge.jelly ? badge.jellyInk
            : badge.tone === "neutral" ? badge.tokens.foreground
            : badge.tone === "info" ? badge.tokens.accentForeground : badge.tokens.statusForeground
        font.pixelSize: badge.jelly ? badge.tokens.uiFontCaption : badge.tokens.fontSmall
        font.weight: badge.jelly ? Font.Medium : Font.Normal
    }
}
