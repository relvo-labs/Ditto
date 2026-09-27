import QtQuick
import Quickshell
import Quickshell.Io

/// Soft-jelly tokens. The values come from the Profile's `appearance`, which
/// Core pushes to the Shell as part of its projection; the Shell keeps no
/// appearance setting of its own. `appearance.tokens` overrides individual
/// values by name (the names are listed in shell/README.md).
///
/// Every token has two alternates: reduced transparency (opaque material,
/// higher contrast) and reduced motion (durations 0; fades instead of
/// movement). The low-power style turns blur and shadow off and is measured as
/// its own style (NFR-05). The system's reduced-motion preference is honoured
/// alongside the Profile's.
QtObject {
    id: tokens

    /// The `appearance` object of the committed projection, or null before
    /// Core has sent one (the defaults below then apply).
    property var appearance: null

    /// Development and measurement switches (G0): environment only.
    readonly property bool environmentReducedMotion: Quickshell.env("DITTO_REDUCED_MOTION") === "1"
    readonly property bool environmentReducedTransparency: Quickshell.env("DITTO_REDUCED_TRANSPARENCY") === "1"
    readonly property bool environmentLowPower: Quickshell.env("DITTO_LOW_POWER_STYLE") === "1"
    /// The desktop's own "animations off" preference, read once at startup.
    property bool systemReducedMotion: false

    readonly property var overrides: appearance && appearance.tokens ? appearance.tokens : ({})
    readonly property bool reducedMotion: environmentReducedMotion || systemReducedMotion
        || (appearance ? appearance.reduced_motion === true : false)
    readonly property bool reducedTransparency: environmentReducedTransparency
        || (appearance ? appearance.reduced_transparency === true : false)
    readonly property bool lowPower: environmentLowPower
        || (appearance ? appearance.low_power_style === true : false)
    readonly property string theme: appearance && appearance.theme ? appearance.theme : "soft-jelly"

    function colorToken(name, fallback) {
        const value = overrides[name];
        return typeof value === "string" && /^#([0-9a-fA-F]{6}|[0-9a-fA-F]{8})$/.test(value) ? value : fallback;
    }

    function numberToken(name, fallback, minimum, maximum) {
        const value = parseFloat(overrides[name]);
        if (isNaN(value)) {
            return fallback;
        }
        return Math.max(minimum, Math.min(maximum, value));
    }

    /// `#rrggbb` with an alpha in [0, 1]; used to derive the translucent
    /// material from an opaque colour so an override keeps both variants.
    function withAlpha(value, alpha) {
        const color = Qt.color(value);
        return Qt.rgba(color.r, color.g, color.b, alpha);
    }

    // ---- colour ----------------------------------------------------------------
    readonly property color accent: colorToken("accent", "#b9a4ff")
    readonly property color onAccent: colorToken("on_accent", "#1a1626")
    readonly property color background: colorToken("background", "#12121a")
    readonly property color surfaceBase: colorToken("surface", "#1d1f2b")
    readonly property color surface: reducedTransparency ? surfaceBase : withAlpha(surfaceBase, 0.62)
    readonly property color surfaceStrong: colorToken("surface_strong", reducedTransparency ? "#2a2e42" : "#242739")
    readonly property color foreground: colorToken("foreground", "#f2f3f8")
    readonly property color foregroundMuted: colorToken("foreground_muted", reducedTransparency ? "#c9cde0" : "#a9aec4")
    readonly property color border: reducedTransparency ? colorToken("border", "#5a6180") : withAlpha(colorToken("border", "#3a3f55"), 0.45)
    readonly property color focus: colorToken("focus", "#f2f3f8")
    readonly property color warning: colorToken("warning", "#ffcf8b")
    readonly property color danger: colorToken("danger", "#ff9b9b")
    readonly property color success: colorToken("success", "#9be3b4")
    readonly property color scrim: reducedTransparency ? "#12121a" : "#b312121a"

    // ---- material --------------------------------------------------------------
    /// Blur is requested only where the compositor offers a background effect;
    /// with reduced transparency or the low-power style it is always 0.
    readonly property real blurRadius: (reducedTransparency || lowPower) ? 0 : numberToken("blur_radius", 18, 0, 64)
    readonly property real surfaceOpacity: reducedTransparency ? 1.0 : numberToken("surface_opacity", 0.94, 0.5, 1.0)
    readonly property bool shadowEnabled: !lowPower
    readonly property real shadowRadius: shadowEnabled ? numberToken("shadow_radius", 14, 0, 48) : 0
    readonly property color shadowColor: "#66000000"

    // ---- shape -----------------------------------------------------------------
    readonly property real radiusScale: numberToken("radius_scale", 1.0, 0, 2)
    readonly property int radiusSmall: Math.round(6 * radiusScale)
    readonly property int radiusMedium: Math.round(12 * radiusScale)
    readonly property int radiusLarge: Math.round(20 * radiusScale)

    // ---- type ------------------------------------------------------------------
    readonly property real fontScale: numberToken("font_scale", 1.0, 0.75, 2)
    readonly property string fontFamily: typeof overrides.font_family === "string" ? overrides.font_family : ""
    readonly property int fontSmall: Math.round(11 * fontScale)
    readonly property int fontBody: Math.round(13 * fontScale)
    readonly property int fontTitle: Math.round(16 * fontScale)
    readonly property int fontHeading: Math.round(21 * fontScale)
    readonly property real lineHeight: 1.35

    // ---- spacing ---------------------------------------------------------------
    readonly property real spaceScale: numberToken("space_scale", 1.0, 0.5, 2)
    readonly property int spaceTight: Math.round(4 * spaceScale)
    readonly property int space: Math.round(8 * spaceScale)
    readonly property int spaceWide: Math.round(16 * spaceScale)
    readonly property int spaceSection: Math.round(24 * spaceScale)
    readonly property int controlHeight: Math.round(30 * fontScale)

    // ---- motion ----------------------------------------------------------------
    /// Movement durations are 0 with reduced motion; fades stay short so a
    /// change is still noticeable without anything moving.
    readonly property int durationFast: reducedMotion ? 0 : 120
    readonly property int durationMedium: reducedMotion ? 0 : 240
    readonly property int durationSlow: reducedMotion ? 0 : 3200
    readonly property int durationFade: reducedMotion ? 90 : 160
    readonly property int easing: Easing.InOutQuad
    readonly property int easingEnter: Easing.OutCubic
    readonly property int easingExit: Easing.InCubic

    /// One read of the desktop preference at startup. It is not watched:
    /// a later change applies at the next Shell start, which is stated in
    /// the personalization center.
    property Process systemMotion: Process {
        running: true
        command: ["sh", "-c", "command -v gsettings >/dev/null && gsettings get org.gnome.desktop.interface enable-animations 2>/dev/null || true"]
        stdout: StdioCollector {
            onStreamFinished: tokens.systemReducedMotion = text.trim() === "false"
        }
    }
}
