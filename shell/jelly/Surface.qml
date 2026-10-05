import QtQuick

/// Base of the Shell's own panels. Keeps the translucency decision in one
/// place so the reduced-transparency switch reaches every surface at once.
/// Providers are loaded from the package store and cannot import this; they
/// draw with the same `tokens` object they are given.
Rectangle {
    id: surface

    required property var tokens

    color: tokens.surface
    radius: tokens.radiusMedium
    border.color: tokens.border
    border.width: 1
    opacity: tokens.surfaceOpacity
}
