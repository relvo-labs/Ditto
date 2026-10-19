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
///
/// Two recipes share the token names. `soft-jelly` (and a Profile without a
/// theme) keeps the dark values Core lists in its token table
/// (`APPEARANCE_TOKENS`); `soft-jelly-light` is the light lavender recipe of
/// the default-desktop reference (docs/design/default-desktop/
/// component-sheet.md, a proposal until the owner confirms it). Which recipe
/// a new Profile starts with, and the defaults Core lists for it, are Core's
/// (#45); this file only answers for the theme it is given.
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
    /// The light recipe; every other theme name keeps the dark values.
    readonly property bool lightRecipe: theme === "soft-jelly-light"
    /// Shader effects (the material's soft shadow) are allowed. Reduced
    /// transparency and the low-power style take the non-shader path; the
    /// content, focus and hit regions are the same on both paths.
    readonly property bool effectsEnabled: !reducedTransparency && !lowPower

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
    // Each dark value is the default in Core's token table; a test there reads
    // this file and compares them, so they stay written out in full.
    // Light values: contrast against the composited surfaces is computed in
    // tests/g4/visual/tst_tokens.qml and listed in component-sheet.md.
    readonly property color accent: lightRecipe ? colorToken("accent", "#9d8cf0") : colorToken("accent", "#b9a4ff")
    // Avoid on + uppercase: QML treats that spelling as a signal handler.
    readonly property color accentForeground: lightRecipe ? colorToken("on_accent", "#1c1830") : colorToken("on_accent", "#1a1626")
    readonly property color background: lightRecipe ? colorToken("background", "#d3cff9") : colorToken("background", "#12121a")
    readonly property color surfaceBase: lightRecipe ? colorToken("surface", "#fbfaff") : colorToken("surface", "#1d1f2b")
    /// Alpha of the translucent surface colour (before `surfaceOpacity`).
    readonly property real surfaceAlpha: reducedTransparency ? 1.0 : (lightRecipe ? 0.9 : 0.62)
    readonly property color surface: reducedTransparency ? surfaceBase : withAlpha(surfaceBase, surfaceAlpha)
    readonly property color surfaceStrong: lightRecipe
        ? colorToken("surface_strong", reducedTransparency ? "#e6e2f8" : "#ece8fb")
        : colorToken("surface_strong", reducedTransparency ? "#2a2e42" : "#242739")
    readonly property color foreground: lightRecipe ? colorToken("foreground", "#211e35") : colorToken("foreground", "#f2f3f8")
    readonly property color foregroundMuted: lightRecipe
        ? colorToken("foreground_muted", reducedTransparency ? "#46425e" : "#57536f")
        : colorToken("foreground_muted", reducedTransparency ? "#c9cde0" : "#a9aec4")
    readonly property color border: lightRecipe
        ? (reducedTransparency ? colorToken("border", "#7d75ad") : withAlpha(colorToken("border", "#b3abe0"), 0.8))
        : (reducedTransparency ? colorToken("border", "#5a6180") : withAlpha(colorToken("border", "#3a3f55"), 0.45))
    readonly property color focus: lightRecipe ? colorToken("focus", "#4c3fb5") : colorToken("focus", "#f2f3f8")
    // Status colours keep their own hues in both recipes (not tinted to the
    // accent); the light ones are dark enough to be read as text.
    readonly property color warning: lightRecipe ? colorToken("warning", "#7a4a00") : colorToken("warning", "#ffcf8b")
    readonly property color danger: lightRecipe ? colorToken("danger", "#a8231b") : colorToken("danger", "#ff9b9b")
    readonly property color success: lightRecipe ? colorToken("success", "#17663a") : colorToken("success", "#9be3b4")
    // Light: a near-white veil, so text drawn straight on it (the launcher
    // grid's names and hint) stays readable; a dark veil left the hint at 2.2:1.
    readonly property color scrim: lightRecipe
        ? (reducedTransparency ? background : withAlpha(surfaceBase, 0.86))
        : (reducedTransparency ? "#12121a" : "#b312121a")

    // Derived values, not overridable on their own: they follow the tokens above.
    /// Status fills are pale in the dark recipe and dark in the light one.
    /// This is separate from the Profile-overridable foreground on accent.
    readonly property color statusForeground: lightRecipe ? "#ffffff" : "#1a1626"
    /// The thin bright edge just inside a surface; none with reduced transparency.
    readonly property color highlight: reducedTransparency ? "transparent"
        : (lightRecipe ? Qt.rgba(1, 1, 1, 0.85) : Qt.rgba(1, 1, 1, 0.08))
    /// The desktop canvas behind every surface while no wallpaper is shown:
    /// a soft gradient in the light recipe, the flat background otherwise.
    readonly property color canvasTop: background
    readonly property color canvasBottom: lightRecipe ? Qt.tint(background, Qt.rgba(1, 1, 1, 0.12)) : background
    readonly property color canvasGlow: lightRecipe ? Qt.rgba(1, 1, 1, 0.42) : "transparent"
    /// The default wallpaper of the light recipe (owner-chosen 2026-10-19,
    /// shell/wallpapers/SOURCES.md). The dark recipe and older Profiles keep
    /// the plain canvas. A per-Profile wallpaper field is still Core's (H2).
    readonly property url wallpaper: lightRecipe ? Qt.resolvedUrl("../wallpapers/soft-jelly-default.jpg") : ""

    // ---- material --------------------------------------------------------------
    /// Blur is requested only where the compositor offers a background effect;
    /// with reduced transparency or the low-power style it is always 0.
    readonly property real blurRadius: (reducedTransparency || lowPower) ? 0 : numberToken("blur_radius", 18, 0, 64)
    readonly property real surfaceOpacity: reducedTransparency ? 1.0 : numberToken("surface_opacity", 0.94, 0.5, 1.0)
    readonly property bool shadowEnabled: !lowPower
    readonly property real shadowRadius: shadowEnabled ? numberToken("shadow_radius", 14, 0, 48) : 0
    readonly property color shadowColor: lightRecipe ? Qt.rgba(0.165, 0.141, 0.345, 0.22) : "#66000000"

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
    /// #66 candidate policy; local scalar animation needs no shader, including
    /// on software renderers and reduced-transparency surfaces. Legacy callers
    /// retain the durations below. No persisted setting or new Profile token.
    readonly property bool motionEnabled: !reducedMotion && !lowPower
    readonly property int motionFeedback: 120
    readonly property int motionPresent: 180
    /// Movement durations are 0 with reduced motion; fades stay short so a
    /// change is still noticeable without anything moving.
    readonly property int durationFast: reducedMotion ? 0 : 120
    readonly property int durationMedium: reducedMotion ? 0 : 240
    readonly property int durationSlow: reducedMotion ? 0 : 3200
    readonly property int durationFade: reducedMotion ? 90 : 160
    readonly property int easing: Easing.InOutQuad
    readonly property int easingEnter: Easing.OutCubic
    readonly property int easingExit: Easing.InCubic

    // ---- #116 Soft Jelly application styles ---------------------------------------
    /// A text token that takes one of `choices`; anything else (or no value)
    /// is `fallback`. Core refuses other values in preflight; this only keeps
    /// an older or hand-edited document drawable.
    function choiceToken(name, fallback, choices) {
        const value = overrides[name];
        return typeof value === "string" && choices.indexOf(value) >= 0 ? value : fallback;
    }
    /// The application style the person chose in personalization (owner
    /// 2026-10-20: three styles, J1 by default): "j1" jelly glass, "j2" gummy,
    /// "j3" bubble. It is the Profile's `appearance.tokens.ui_style`, set by
    /// ChangeSet like every other token; no value is J1, so a Profile written
    /// before the token existed is not rewritten.
    readonly property string uiStyleChosen: choiceToken("ui_style", "j1", ["j1", "j2", "j3"])
    /// What the Shell's own windows (centers, chat, approval) and the pill
    /// Dock draw. The styles belong to the light recipe: `soft-jelly` (dark)
    /// and a Profile without a theme keep the existing presentation, "".
    /// Writable only so tests can render the light recipe's earlier
    /// presentation for comparison; nothing in the Shell assigns it.
    property string uiStyle: lightRecipe ? uiStyleChosen : ""
    readonly property bool uiCandidate: uiStyle !== ""
    readonly property bool uiJ1: uiStyle === "j1"
    readonly property bool uiJ2: uiStyle === "j2"
    readonly property bool uiJ3: uiStyle === "j3"
    /// Gloss (top sheen, iridescent rim) and soft shadows: plain gradients
    /// and stacked rectangles, no shader. Reduced transparency drops the
    /// gloss and makes every fill opaque; the low-power style drops both.
    readonly property bool uiGloss: uiCandidate && !reducedTransparency && !lowPower
    readonly property bool uiShadows: uiCandidate && !lowPower
    function uiFill(value, alpha) {
        return reducedTransparency ? Qt.color(value) : withAlpha(value, alpha);
    }

    // Colour. Every text/fill pair is checked in tests/g4/visual/unit/
    // tst_ui_style.qml and, over the real wallpaper, by capture/ui_contrast.py.
    readonly property color uiInk: uiJ2 ? "#2a1a40" : uiJ3 ? "#221f3c" : "#231d3b"
    readonly property color uiInkMuted: reducedTransparency ? "#423c5e" : uiJ2 ? "#564c72" : uiJ3 ? "#524f6f" : "#544e70"
    /// Disabled labels: still legible (about 3:1), never mistaken for a
    /// sole option, which keeps full ink.
    readonly property color uiInkDisabled: "#7d7896"
    /// The window behind the content.
    readonly property color uiCanvas: uiJ2 ? uiFill("#f5ebfb", 0.98) : uiJ3 ? uiFill("#f6f7ff", 0.86) : uiFill("#f4f2fd", 0.88)
    /// J3's water tint at the bottom of a window (gloss only).
    readonly property color uiCanvasLow: uiJ3 ? uiFill("#eef5fb", 0.86) : uiCanvas
    readonly property color uiSidebar: uiJ2 ? uiFill("#ecdcf9", 1.0) : uiJ3 ? "transparent" : uiFill("#e9e5fb", 0.72)
    readonly property color uiCard: uiJ2 ? uiFill("#fffbff", 1.0) : uiJ3 ? uiFill("#ffffff", 0.6) : uiFill("#ffffff", 0.74)
    readonly property color uiCardBorder: reducedTransparency ? "#8f86bf"
        : uiJ2 ? "#e6d6f8" : uiJ3 ? Qt.rgba(0.80, 0.78, 0.97, 0.7) : Qt.rgba(0.79, 0.75, 0.94, 0.6)
    /// Bright inner edge of a jelly surface (none with reduced transparency).
    readonly property color uiCardHighlight: uiGloss ? Qt.rgba(1, 1, 1, uiJ2 ? 0.9 : 0.8) : "transparent"
    readonly property color uiShadow: uiJ2 ? Qt.rgba(0.48, 0.30, 0.72, 0.26) : uiJ3 ? Qt.rgba(0.30, 0.45, 0.65, 0.12) : Qt.rgba(0.27, 0.22, 0.55, 0.16)
    /// J2's gummy lip: a solid, unblurred edge under raised surfaces.
    readonly property color uiLip: "#dcc6f5"
    readonly property color uiAccentLip: "#4c2ab0"
    /// J2 selects with a filled lilac gummy (ink text) instead of a white bead.
    readonly property color uiSelectFill: uiJ2 ? "#e2cdfb" : "#ffffff"
    /// The recessed track of a segmented control and the selected bead in it.
    readonly property color uiTrack: uiJ2 ? uiFill("#eadcfa", 1.0) : uiJ3 ? uiFill("#eef0fd", 0.55) : uiFill("#e4dff8", 0.9)
    readonly property color uiBead: "#ffffff"
    readonly property color uiBeadEdge: uiJ3 && !reducedTransparency ? "#c8bdf6" : uiJ2 ? "#cdbdf6" : "#d3cbf4"
    /// Selection marker: the small filled bead in front of a selected item.
    readonly property color uiSelectDot: uiJ2 ? "#7a3fd8" : uiJ3 ? "#5f86d6" : "#7262dc"
    /// Primary action fill (white text). J2 adds a jelly gradient.
    readonly property color uiAccent: uiJ2 ? "#6a3ad6" : uiJ3 ? "#5f57cf" : "#6552d6"
    readonly property color uiAccentTop: uiJ2 ? "#7a58e6" : uiJ3 ? "#6b63d6" : "#7262dc"
    readonly property color uiOnAccent: "#ffffff"
    /// Accent-coloured text (links, a selected label's tint): darker than
    /// the fill so it reads on the translucent canvas.
    readonly property color uiAccentInk: "#4a3cb5"
    readonly property color uiTonal: uiJ2 ? "#efe2fc" : uiJ3 ? uiFill("#ffffff", 0.7) : uiFill("#ebe7fb", 0.92)
    readonly property color uiTonalHover: uiJ2 ? "#e6d4fb" : uiJ3 ? uiFill("#ffffff", 0.9) : "#e2dcfa"
    readonly property color uiGhostHover: Qt.rgba(0.42, 0.33, 0.84, 0.08)
    readonly property color uiFocus: "#4c3fb5"
    readonly property color uiSeparator: reducedTransparency ? "#b9b1df" : Qt.rgba(0.48, 0.42, 0.80, 0.22)
    readonly property color uiSuccess: "#256446"
    readonly property color uiSuccessFill: "#dcf2e6"
    readonly property color uiWarning: "#7a4a05"
    readonly property color uiWarningFill: "#fcebc9"
    readonly property color uiDanger: "#a02c4a"
    readonly property color uiDangerFill: "#fae1e8"
    readonly property color uiDangerSolid: "#b23a59"
    readonly property color uiInfo: "#4a3eab"
    readonly property color uiInfoFill: "#e7e3fb"
    /// The iridescent rim (pink → lavender → aqua) of J3, softer in J1.
    readonly property var uiIris: ["#f6c9e8", "#cbbef8", "#b5e9f1"]
    /// Window control beads: three lavender shades; close turns soft red
    /// on hover or keyboard focus.
    readonly property color uiBeadMinimize: uiJ2 ? "#d9cbfb" : "#ddd6fa"
    readonly property color uiBeadMaximize: uiJ2 ? "#b9a2f5" : "#c2b6f3"
    readonly property color uiBeadClose: uiJ2 ? "#9476ec" : "#a596ea"
    readonly property color uiBeadCloseHot: "#e26d84"
    readonly property color uiBeadGlyph: "#2b2350"

    // Shape, type and spacing (8 pt grid). Profile radius/font/space scales apply.
    readonly property int uiRadiusWindow: Math.round((uiJ1 ? 18 : 22) * radiusScale)
    readonly property int uiRadiusCard: Math.round((uiJ2 ? 20 : uiJ3 ? 26 : 16) * radiusScale)
    readonly property int uiRadiusControl: Math.round((uiJ1 ? 10 : 16) * radiusScale)
    readonly property int uiFontPage: Math.round((uiJ2 ? 26 : 24) * fontScale)
    readonly property int uiFontGroup: Math.round(13 * fontScale)
    readonly property int uiFontLabel: Math.round(14 * fontScale)
    readonly property int uiFontBody: Math.round(14 * fontScale)
    readonly property int uiFontCaption: Math.round(12 * fontScale)
    readonly property int uiFontCardTitle: Math.round(16 * fontScale)
    readonly property int uiGap: Math.round(8 * spaceScale)
    readonly property int uiPadCard: Math.round((uiJ3 ? 24 : 16) * spaceScale)
    readonly property int uiPadPage: Math.round(32 * spaceScale)
    readonly property int uiGapGroup: Math.round(24 * spaceScale)
    readonly property int uiControlHeight: Math.round(32 * fontScale)
    readonly property int uiRowHeight: Math.round((uiJ3 ? 56 : 48) * fontScale)
    readonly property int uiHeaderHeight: Math.round(52 * fontScale)

    // Motion: press squashes the control's face (J2 the most), 120 ms OutCubic;
    // hit targets never scale. Off with reduced motion or the low-power style.
    readonly property real uiPressScaleX: uiJ2 ? 1.03 : uiJ3 ? 0.95 : 0.97
    readonly property real uiPressScaleY: uiJ2 ? 0.90 : uiJ3 ? 0.95 : 0.97

    // What the centers and chat pages draw raw text and their own plates with.
    // Unset style: exactly the existing token (the legacy test compares pixels);
    // a candidate: its ink, caption size and card.
    readonly property color appInk: uiCandidate ? uiInk : foreground
    readonly property color appInkMuted: uiCandidate ? uiInkMuted : foregroundMuted
    readonly property color appWarning: uiCandidate ? uiWarning : warning
    readonly property color appDanger: uiCandidate ? uiDanger : danger
    readonly property color appSuccess: uiCandidate ? uiSuccess : success
    readonly property int appFontCaption: uiCandidate ? uiFontCaption : fontSmall
    readonly property int appFontBody: uiCandidate ? uiFontBody : fontBody
    readonly property int appFontTitle: uiCandidate ? uiFontCardTitle : fontTitle
    readonly property int appFontHeading: uiCandidate ? uiFontPage : fontHeading
    readonly property int appPagePad: uiCandidate ? uiPadPage : spaceSection
    readonly property color appPlate: uiCandidate ? uiCard : surface
    readonly property color appPlateStrong: uiCandidate ? uiTrack : surfaceStrong
    readonly property color appPlateBorder: uiCandidate ? uiCardBorder : border
    readonly property int appPlateRadius: uiCandidate ? uiRadiusControl : radiusSmall

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
