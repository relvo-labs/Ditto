import QtQuick

/// Panel and dock base. Keeps the translucency decision in one place so the
/// reduced-transparency token switch reaches every surface at once.
Rectangle {
    id: surface

    required property var tokens

    color: tokens.surface
    radius: tokens.radiusMedium
    border.color: tokens.border
    border.width: 1
    opacity: tokens.surfaceOpacity
}
