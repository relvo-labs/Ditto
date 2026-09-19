import QtQuick

/// The token minimum set for G0. Every colour has a reduced-transparency value
/// and every duration has a reduced-motion value, because retrofitting those
/// two switches would mean touching every component that assumed otherwise.
QtObject {
    id: tokens

    property bool reducedTransparency: false
    property bool reducedMotion: false

    readonly property color background: "#12121a"
    readonly property color surface: reducedTransparency ? "#1d1f2b" : "#991d1f2b"
    readonly property color surfaceStrong: "#242739"
    readonly property color foreground: "#f2f3f8"
    readonly property color foregroundMuted: "#a9aec4"
    readonly property color accent: "#b7a6ff"
    readonly property color border: reducedTransparency ? "#3a3f55" : "#663a3f55"
    readonly property color warning: "#ffcf8b"

    readonly property real blurRadius: reducedTransparency ? 0 : 18
    readonly property real surfaceOpacity: reducedTransparency ? 1.0 : 0.88

    readonly property int radiusSmall: 6
    readonly property int radiusMedium: 12
    readonly property int radiusLarge: 20

    readonly property int fontSmall: 11
    readonly property int fontBody: 13
    readonly property int fontTitle: 16
    readonly property real lineHeight: 1.35

    readonly property int spaceTight: 4
    readonly property int space: 8
    readonly property int spaceWide: 16
    readonly property int spaceSection: 24

    readonly property int durationFast: reducedMotion ? 0 : 120
    readonly property int durationMedium: reducedMotion ? 0 : 240
    readonly property int durationSlow: reducedMotion ? 0 : 3200
    readonly property int easing: Easing.InOutQuad
}
