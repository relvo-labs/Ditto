import QtQuick

/// The soft-jelly material for the Shell's own surfaces (centers, change bar).
/// Translucency, border and shadow all come from the tokens, so reduced
/// transparency and the low-power style reach every surface at once. The
/// shadow is a second rectangle, not an effect pass: it costs nothing per
/// frame and disappears entirely in the low-power style.
Item {
    id: material

    required property var tokens
    property real radius: tokens.radiusMedium
    property color color: tokens.surface
    property bool raised: true

    Rectangle {
        visible: material.raised && material.tokens.shadowEnabled
        anchors.fill: parent
        anchors.topMargin: 3
        anchors.leftMargin: 1
        anchors.rightMargin: -1
        anchors.bottomMargin: -4
        radius: material.radius + 2
        color: material.tokens.shadowColor
        opacity: 0.55
    }

    Rectangle {
        anchors.fill: parent
        radius: material.radius
        color: material.color
        border.color: material.tokens.border
        border.width: 1
        opacity: material.tokens.surfaceOpacity
    }
}
