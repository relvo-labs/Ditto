import QtQuick
import QtTest
import "../../../../shell/jelly" as Jelly

// The real shell/jelly/Tokens.qml, with Quickshell replaced by the stubs in
// ../stubs (no Wayland session here). Development evidence only.
//
// Contrast: WCAG 2.x relative luminance. Each surface is composited the way
// it is drawn (translucent fill × surfaceOpacity over the canvas, with the
// densest shadow under it), so the ratio is for what is on screen, not for
// the token alone. Over a real wallpaper the translucent case changes; the
// reduced-transparency case does not.
TestCase {
    id: testCase
    name: "SoftJellyTokens"

    Component { id: tokensFactory; Jelly.Tokens {} }

    function make(appearance) {
        return createTemporaryObject(tokensFactory, testCase, { appearance: appearance });
    }

    function light(extra) {
        return Object.assign({ theme: "soft-jelly-light", tokens: {}, locale: "zh-TW" }, extra || {});
    }

    // ---- colour arithmetic ------------------------------------------------
    function channel(c) {
        return c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4);
    }
    function luminance(c) {
        return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b);
    }
    function contrast(a, b) {
        const la = luminance(a), lb = luminance(b);
        return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05);
    }
    /// `top` drawn with `alpha` (its own alpha × extra opacity) over an opaque `bottom`.
    function over(top, alpha, bottom) {
        return { r: top.r * alpha + bottom.r * (1 - alpha), g: top.g * alpha + bottom.g * (1 - alpha),
                 b: top.b * alpha + bottom.b * (1 - alpha) };
    }
    function hex(c) {
        const h = v => ("0" + Math.round(v * 255).toString(16)).slice(-2);
        return "#" + h(c.r) + h(c.g) + h(c.b);
    }
    function hue(c) {
        const max = Math.max(c.r, c.g, c.b), min = Math.min(c.r, c.g, c.b), d = max - min;
        if (d === 0) return 0;
        let h = max === c.r ? ((c.g - c.b) / d) % 6 : max === c.g ? (c.b - c.r) / d + 2 : (c.r - c.g) / d + 4;
        h *= 60;
        return h < 0 ? h + 360 : h;
    }
    function hueDistance(a, b) {
        const d = Math.abs(hue(a) - hue(b));
        return Math.min(d, 360 - d);
    }

    /// The surfaces text is drawn on, composited.
    function surfaces(t) {
        const canvas = t.background;
        const shadowed = over(t.shadowColor, t.shadowEnabled ? t.shadowColor.a : 0, canvas);
        const fillAlpha = t.surface.a * t.surfaceOpacity;
        const strong = over(t.surfaceStrong, t.surfaceStrong.a, canvas);
        return {
            "material": over(t.surface, fillAlpha, canvas),
            "material+shadow": over(t.surface, fillAlpha, shadowed),
            "surfaceStrong": strong,
            // Full-bleed window colour of the centers (Centers.qml).
            "canvas": canvas,
            // Every consumer that draws text on a composed background
            // (`git grep scrim` and the full-bleed/stacked surfaces of the
            // launchers, notifications and centers; component-sheet.md §2):
            // LauncherGrid.qml: hint (foregroundMuted), names (foreground) and
            // the current tile's focus border straight on the scrim.
            "launcher_grid.scrim": over(t.scrim, t.scrim.a, canvas),
            // LauncherSearch.qml: query field (surface) on its panel (surfaceStrong).
            "launcher_search.field": over(t.surface, t.surface.a, strong),
            // NotificationArea.qml: card (surfaceStrong × surfaceOpacity).
            "notifications.card": over(t.surfaceStrong, t.surfaceStrong.a * t.surfaceOpacity, canvas),
            // Centers' panels and rows (surface, no extra opacity) on the window colour.
            "centers.surface": over(t.surface, t.surface.a, canvas)
        };
    }

    function report(mode, t) {
        const lines = [];
        const grounds = surfaces(t);
        const texts = { foreground: t.foreground, foregroundMuted: t.foregroundMuted,
                        warning: t.warning, danger: t.danger, success: t.success };
        for (const name in texts) {
            for (const ground in grounds) {
                const ratio = contrast(texts[name], grounds[ground]);
                lines.push({ mode: mode, text: name, ground: ground, groundHex: hex(grounds[ground]),
                             textHex: hex(texts[name]), ratio: ratio, minimum: 4.5 });
            }
        }
        for (const ground in grounds) {
            lines.push({ mode: mode, text: "focus (ring)", ground: ground, groundHex: hex(grounds[ground]),
                         textHex: hex(t.focus), ratio: contrast(t.focus, grounds[ground]), minimum: 3 });
        }
        lines.push({ mode: mode, text: "accentForeground", ground: "accent", groundHex: hex(t.accent),
                     textHex: hex(t.accentForeground), ratio: contrast(t.accentForeground, t.accent), minimum: 4.5 });
        for (const line of lines) {
            console.log("CONTRAST " + [line.mode, line.text, line.textHex, line.ground, line.groundHex,
                                       line.ratio.toFixed(2), line.minimum].join(" "));
        }
        return lines;
    }

    // ---- tests ------------------------------------------------------------
    function test_dark_recipe_is_unchanged_without_a_theme() {
        for (const appearance of [null, { theme: "soft-jelly", tokens: {}, locale: "zh-TW" }]) {
            const t = make(appearance);
            verify(!t.lightRecipe);
            compare(String(t.background), "#12121a");
            compare(String(t.surfaceBase), "#1d1f2b");
            fuzzyCompare(t.surface.a, 0.62, 0.01);
            compare(String(t.foreground), "#f2f3f8");
            compare(String(t.warning), "#ffcf8b");
            compare(String(t.canvasTop), String(t.background));
            compare(t.canvasGlow.a, 0);
        }
    }

    function test_light_normal() {
        const t = make(light());
        verify(t.lightRecipe);
        compare(String(t.background), "#d3cff9");
        compare(String(t.surfaceBase), "#fbfaff");
        fuzzyCompare(t.surface.a, 0.9, 0.01);
        fuzzyCompare(t.surfaceOpacity, 0.94, 0.001);
        compare(t.blurRadius, 18);
        verify(t.shadowEnabled);
        compare(t.shadowRadius, 14);
        verify(t.effectsEnabled);
        fuzzyCompare(t.highlight.a, 0.85, 0.01);
        verify(t.canvasGlow.a > 0);
        verify(luminance(t.canvasBottom) > luminance(t.canvasTop));
    }

    function test_light_reduced_transparency() {
        const t = make(light({ reduced_transparency: true }));
        compare(t.surface.a, 1);
        compare(t.surfaceOpacity, 1);
        compare(t.blurRadius, 0);
        verify(!t.effectsEnabled);
        compare(t.highlight.a, 0);
        compare(t.border.a, 1);
        compare(String(t.border), "#7d75ad");
        compare(String(t.foregroundMuted), "#46425e");
        compare(String(t.surfaceStrong), "#e6e2f8");
        compare(t.scrim.a, 1);
    }

    function test_light_low_power() {
        const t = make(light({ low_power_style: true }));
        compare(t.blurRadius, 0);
        verify(!t.shadowEnabled);
        compare(t.shadowRadius, 0);
        verify(!t.effectsEnabled);
        // Low power drops effects, not translucency: that is the other switch.
        fuzzyCompare(t.surface.a, 0.9, 0.01);
    }

    function test_overrides_still_apply_in_the_light_recipe() {
        const t = make(light({ tokens: { accent: "#b9a4ff", background: "not-a-colour", surface_opacity: "0.7" } }));
        compare(String(t.accent), "#b9a4ff");
        compare(String(t.background), "#d3cff9");
        fuzzyCompare(t.surfaceOpacity, 0.7, 0.001);
    }

    function test_status_colours_keep_their_hues() {
        for (const appearance of [light(), light({ reduced_transparency: true }), null]) {
            const t = make(appearance);
            for (const status of [t.warning, t.danger, t.success]) {
                verify(hueDistance(status, t.accent) >= 60,
                       "status hue " + hue(status).toFixed(0) + " too close to accent " + hue(t.accent).toFixed(0));
            }
        }
    }

    function test_each_recipe_accent_contrast_meets_aa() {
        for (const theme of ["no-theme", "soft-jelly", "soft-jelly-light"]) {
            const t = make(theme === "no-theme" ? { tokens: {} } : { theme: theme, tokens: {} });
            const ratio = contrast(t.accentForeground, t.accent);
            console.log("CONTRAST " + [theme, "accentForeground", hex(t.accentForeground), "accent", hex(t.accent), ratio.toFixed(2), 4.5].join(" "));
            verify(ratio >= 4.5, theme + ": accent text contrast " + ratio);
        }
    }

    function test_all_recipes_text_contrast_meets_aa() {
        const modes = {
            "normal": light(),
            "reduced-transparency": light({ reduced_transparency: true }),
            "low-power": light({ low_power_style: true }),
            // The default Profile overrides only the accent (defaults.rs).
            "normal+profile-accent": light({ tokens: { accent: "#b9a4ff" } })
        };
        for (const theme of ["no-theme", "soft-jelly"]) {
            for (const mode of ["normal", "reduced-transparency", "low-power"]) {
                const appearance = { tokens: {}, reduced_transparency: mode === "reduced-transparency", low_power_style: mode === "low-power" };
                if (theme !== "no-theme") appearance.theme = theme;
                modes[theme + "/" + mode] = appearance;
            }
        }
        const failures = [];
        for (const mode in modes) {
            for (const line of report(mode, make(modes[mode]))) {
                if (line.ratio < line.minimum) {
                    failures.push(line.mode + " " + line.text + " on " + line.ground + " " + line.ratio.toFixed(2));
                }
            }
        }
        compare(failures, []);
    }
}
