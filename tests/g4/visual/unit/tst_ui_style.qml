import QtQuick
import QtTest
import DittoStub
import Quickshell
import "../../../../shell/jelly" as Jelly
import "../../../../shell/ui" as Ui

// #116 Soft Jelly application candidates: the opt-in style switch and the new
// shared controls (SegmentedControl, ListRow/GroupedList, OverflowMenu,
// WindowControls), driven with real key events. Development evidence only:
// offscreen, Quickshell stubbed, no compositor, no screen reader.
TestCase {
    id: testCase
    name: "UiStyleCandidates"
    width: 900; height: 600
    visible: true
    when: windowShown

    property int outerEscapes: 0
    Item { id: desktop; width: 900; height: 600; Keys.onEscapePressed: testCase.outerEscapes += 1 }
    Component { id: tokenFactory; Jelly.Tokens {} }
    Component { id: segmentedFactory; Ui.SegmentedControl {} }
    Component { id: choiceFactory; Ui.Choice {} }
    Component { id: overflowFactory; Ui.OverflowMenu {} }
    Component { id: controlsFactory; Ui.WindowControls {} }
    Component { id: buttonFactory; Ui.Button { text: "Fixture" } }
    Component {
        id: groupFactory
        Ui.GroupedList {
            id: group
            title: "Group"
            note: "A long explanation that has to wrap onto a second line instead of running past the edge of the card."
            Ui.ListRow { objectName: "rowA"; tokens: group.tokens; label: "Row A"; caption: "Caption A" }
            Ui.ListRow { objectName: "rowB"; tokens: group.tokens; label: "Row B" }
        }
    }

    readonly property var options: [
        { value: "a", label: "Alpha" }, { value: "b", label: "Beta" }, { value: "c", label: "Gamma" }
    ]

    function tokensFor(style, extra) {
        const tokens = createTemporaryObject(tokenFactory, testCase, {
            appearance: Object.assign({ theme: "soft-jelly-light", tokens: {} }, extra || {})
        });
        tokens.uiStyle = style;
        return tokens;
    }

    function find(root, name) {
        if (!root) return null;
        if (root.objectName === name) return root;
        for (const child of root.children) {
            const found = find(child, name);
            if (found) return found;
        }
        return null;
    }

    function contrast(a, b) {
        const linear = c => c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4);
        const luminance = c => 0.2126 * linear(c.r) + 0.7152 * linear(c.g) + 0.0722 * linear(c.b);
        const la = luminance(a), lb = luminance(b);
        return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05);
    }

    function init() {
        StubDesktop.layer = desktop;
        Quickshell.environment = ({});
    }

    // ---- the switch -----------------------------------------------------------------
    function test_style_comes_from_the_environment_and_defaults_off() {
        compare(createTemporaryObject(tokenFactory, testCase).uiStyle, "", "unset: existing presentation");
        for (const value of ["j1", "j2", "j3"]) {
            Quickshell.environment = ({ DITTO_UI_STYLE: value });
            const tokens = createTemporaryObject(tokenFactory, testCase);
            compare(tokens.uiStyle, value);
            verify(tokens.uiCandidate);
        }
        for (const value of ["J1", "macos", "1", ""]) {
            Quickshell.environment = ({ DITTO_UI_STYLE: value });
            compare(createTemporaryObject(tokenFactory, testCase).uiStyle, "", "unknown value '" + value + "' counts as unset");
        }
    }

    function test_unset_style_keeps_every_app_alias_equal_to_its_token() {
        for (const theme of [null, "soft-jelly", "soft-jelly-light"]) {
            const tokens = createTemporaryObject(tokenFactory, testCase, { appearance: theme ? { theme: theme, tokens: {} } : null });
            verify(!tokens.uiCandidate);
            compare(tokens.appInk, tokens.foreground);
            compare(tokens.appInkMuted, tokens.foregroundMuted);
            compare(tokens.appWarning, tokens.warning);
            compare(tokens.appDanger, tokens.danger);
            compare(tokens.appSuccess, tokens.success);
            compare(tokens.appFontCaption, tokens.fontSmall);
            compare(tokens.appFontBody, tokens.fontBody);
            compare(tokens.appFontTitle, tokens.fontTitle);
            compare(tokens.appFontHeading, tokens.fontHeading);
            compare(tokens.appPagePad, tokens.spaceSection);
            compare(tokens.appPlate, tokens.surface);
            compare(tokens.appPlateStrong, tokens.surfaceStrong);
            compare(tokens.appPlateBorder, tokens.border);
            compare(tokens.appPlateRadius, tokens.radiusSmall);
            verify(!tokens.uiGloss && !tokens.uiShadows);
        }
    }

    function test_type_scale_and_spacing_floor_data() {
        return ["j1", "j2", "j3"].map(style => ({ tag: style, style: style }));
    }
    function test_type_scale_and_spacing_floor(row) {
        const tokens = tokensFor(row.style);
        verify(tokens.uiFontPage >= 22 && tokens.uiFontPage <= 26);
        compare(tokens.uiFontGroup, 13);
        verify(tokens.uiFontLabel >= 13 && tokens.uiFontLabel <= 14);
        verify(tokens.uiFontCaption >= 12, "CJK captions are at least 12 px");
        verify(tokens.appFontCaption >= 12);
        verify(tokens.uiRowHeight >= 36);
        verify(tokens.uiPadCard >= 16);
        compare(tokens.uiGap % 8, 0);
        compare(tokens.uiPadPage % 8, 0);
    }

    // Text/fill pairs on opaque fills; the composite over the wallpaper is
    // capture/ui_contrast.py's (it prints the full table).
    function test_fill_contrast_data() {
        const rows = [];
        for (const style of ["j1", "j2", "j3"])
            for (const mode of ["normal", "reduced-transparency", "low-power"])
                rows.push({ tag: style + "/" + mode, style: style, mode: mode });
        return rows;
    }
    function test_fill_contrast(row) {
        const tokens = tokensFor(row.style, { reduced_transparency: row.mode === "reduced-transparency", low_power_style: row.mode === "low-power" });
        const pairs = [
            ["onAccent/accent", tokens.uiOnAccent, tokens.uiAccent, 4.5],
            ["onAccent/accentTop", tokens.uiOnAccent, tokens.uiAccentTop, 4.5],
            ["white/dangerSolid", tokens.uiOnAccent, tokens.uiDangerSolid, 4.5],
            ["success/fill", tokens.uiSuccess, tokens.uiSuccessFill, 4.5],
            ["warning/fill", tokens.uiWarning, tokens.uiWarningFill, 4.5],
            ["danger/fill", tokens.uiDanger, tokens.uiDangerFill, 4.5],
            ["info/fill", tokens.uiInfo, tokens.uiInfoFill, 4.5],
            ["ink/bead", tokens.uiInk, tokens.uiBead, 4.5],
            ["muted/bead", tokens.uiInkMuted, tokens.uiBead, 4.5],
            ["glyph/minimize", tokens.uiBeadGlyph, tokens.uiBeadMinimize, 4.5],
            ["glyph/maximize", tokens.uiBeadGlyph, tokens.uiBeadMaximize, 4.5],
            ["glyph/closeHot", tokens.uiBeadGlyph, tokens.uiBeadCloseHot, 4.5],
            ["disabled/bead", tokens.uiInkDisabled, tokens.uiBead, 3.0],
            ["focus/bead", tokens.uiFocus, tokens.uiBead, 3.0]
        ];
        for (const [name, fg, bg, floor] of pairs) {
            const ratio = contrast(Qt.color(fg), Qt.color(bg));
            console.log("UI_CONTRAST " + JSON.stringify({ style: row.style, mode: row.mode, pair: name, ratio: Math.round(ratio * 100) / 100 }));
            verify(ratio >= floor, row.tag + " " + name + " " + ratio.toFixed(2));
        }
        // The tokens ui_contrast.py composites over the wallpaper.
        console.log("UI_TOKENS " + JSON.stringify({ style: row.style, mode: row.mode,
            canvas: String(tokens.uiCanvas), sidebar: String(tokens.uiSidebar), card: String(tokens.uiCard),
            track: String(tokens.uiTrack), tonal: String(tokens.uiTonal), ink: String(tokens.uiInk), muted: String(tokens.uiInkMuted),
            accentInk: String(tokens.uiAccentInk), warning: String(tokens.uiWarning), danger: String(tokens.uiDanger),
            success: String(tokens.uiSuccess), focus: String(tokens.uiFocus) }));
        compare(tokens.uiGloss, row.mode === "normal");
        compare(tokens.uiShadows, row.mode !== "low-power");
        if (row.mode === "reduced-transparency") {
            for (const fill of [tokens.uiCanvas, tokens.uiCard, tokens.uiTrack])
                compare(Qt.color(fill).a, 1, "reduced transparency: opaque fills");
        }
    }

    // ---- SegmentedControl -------------------------------------------------------------
    function test_segmented_keyboard_and_names_data() {
        return ["j1", "j2", "j3"].map(style => ({ tag: style, style: style }));
    }
    function test_segmented_keyboard_and_names(row) {
        const tokens = tokensFor(row.style);
        const control = createTemporaryObject(segmentedFactory, desktop, { tokens: tokens, options: options, value: "b", accessibleName: "Fixture group" });
        const chosen = [];
        control.chosen.connect(value => chosen.push(value));
        waitForRendering(control);
        compare(control.Accessible.role, Accessible.Grouping);
        compare(control.Accessible.name, "Fixture group");
        const segments = [0, 1, 2].map(i => find(control, "segment_" + i));
        for (let i = 0; i < 3; i++) {
            verify(segments[i] !== null);
            compare(segments[i].Accessible.role, Accessible.RadioButton);
            compare(segments[i].Accessible.name, options[i].label);
            compare(segments[i].Accessible.checked, i === 1);
            verify(segments[i].height >= 32 || segments[i].height >= tokens.uiControlHeight);
        }
        // Roving tab stop: only the selected segment takes Tab.
        compare(segments.map(s => s.activeFocusOnTab), [false, true, false]);
        segments[1].forceActiveFocus();
        keyClick(Qt.Key_Right);
        verify(segments[2].activeFocus, "Right moves focus");
        compare(chosen.length, 0, "moving focus does not choose");
        keyClick(Qt.Key_Right);
        verify(segments[0].activeFocus, "wraps to the first");
        keyClick(Qt.Key_Left);
        verify(segments[2].activeFocus);
        keyClick(Qt.Key_Home);
        verify(segments[0].activeFocus);
        keyClick(Qt.Key_End);
        verify(segments[2].activeFocus);
        keyClick(Qt.Key_Space);
        keyClick(Qt.Key_Left);
        keyClick(Qt.Key_Return);
        compare(chosen, ["c", "b"]);
        // The selected bead and the primary action never share a fill.
        const bead = find(control, "segmentBead_1");
        verify(bead !== null && bead.visible);
        verify(!Qt.colorEqual(bead.fill, tokens.uiAccent), "selection is not the primary-action fill");
        verify(find(control, "segmentDot_1").visible, "selection also has a marker, not only a fill");
        verify(!find(control, "segmentDot_0").visible);
        // No ✓ character anywhere.
        const walk = item => { for (const child of item.children) { if (child.text !== undefined) verify(String(child.text).indexOf("✓") < 0); walk(child); } };
        walk(control);
    }

    function test_segmented_sole_option_and_disabled_are_distinct() {
        const tokens = tokensFor("j1");
        const sole = createTemporaryObject(segmentedFactory, desktop, { tokens: tokens, options: [options[0]], value: "a", accessibleName: "Sole" });
        const disabled = createTemporaryObject(segmentedFactory, desktop, { tokens: tokens, options: options, value: "a", accessibleName: "Off", enabled: false });
        waitForRendering(sole);
        const chip = find(sole, "segmentSoleChip");
        verify(chip !== null && chip.visible, "a sole option is a static chip");
        verify(find(sole, "segment_0") === null || !find(sole, "segment_0").visible, "no radio button for a sole option");
        compare(chip.Accessible.role, Accessible.StaticText);
        verify(chip.Accessible.name.indexOf("Alpha") === 0);
        verify(!chip.activeFocusOnTab, "nothing to choose: not a tab stop");
        compare(String(find(chip, "segmentSoleLabel").color), String(tokens.uiInk), "full ink: not mistaken for disabled");
        const off = find(disabled, "segment_1");
        verify(!off.activeFocusOnTab && !find(disabled, "segment_0").activeFocusOnTab);
        compare(String(find(off, "segmentLabel_1").color), String(tokens.uiInkDisabled));
    }

    function test_choice_delegates_to_segmented_only_with_a_style() {
        const legacy = createTemporaryObject(choiceFactory, desktop, { tokens: tokensFor(""), options: options, value: "a" });
        const styled = createTemporaryObject(choiceFactory, desktop, { tokens: tokensFor("j2"), options: options, value: "a" });
        waitForRendering(styled);
        compare(find(legacy, "choiceSegmented"), null, "no candidate control without a style");
        const segmented = find(styled, "choiceSegmented");
        verify(segmented !== null && segmented.visible);
        verify(styled.implicitWidth > 0 && styled.implicitWidth === segmented.implicitWidth);
    }

    // ---- ListRow / GroupedList ---------------------------------------------------------
    function test_grouped_list_rows() {
        const tokens = tokensFor("j3");
        const group = createTemporaryObject(groupFactory, desktop, { tokens: tokens, width: 420 });
        waitForRendering(group);
        const a = find(group, "rowA"), b = find(group, "rowB");
        verify(a.height >= tokens.uiRowHeight && b.height >= tokens.uiRowHeight);
        verify(!find(a, "listRowSeparator").visible, "no separator above the first row");
        verify(find(b, "listRowSeparator").visible);
        compare(a.Accessible.role, Accessible.Grouping);
        compare(a.Accessible.name, "Row A");
        const note = find(group, "sectionNote");
        verify(note.lineCount >= 2, "the note wraps");
        verify(note.width <= group.width);
        compare(note.font.pixelSize, tokens.uiFontCaption);
        compare(find(group, "sectionTitle").font.pixelSize, tokens.uiFontGroup);
        verify(find(group, "sectionCard").visible, "rows sit in a card");
    }

    // ---- OverflowMenu -------------------------------------------------------------------
    function test_overflow_keyboard_and_escape_data() {
        return ["j1", "j2", "j3"].map(style => ({ tag: style, style: style }));
    }
    function test_overflow_keyboard_and_escape(row) {
        const tokens = tokensFor(row.style);
        const menu = createTemporaryObject(overflowFactory, desktop, {
            tokens: tokens, x: 400, y: 40, accessibleName: "More actions: Fixture",
            items: [{ id: "copy", label: "Copy" }, { id: "export", label: "Export" },
                    { id: "locked", label: "Locked", enabled: false, reason: "Not now" },
                    { id: "delete", label: "Delete", danger: true }]
        });
        const fired = [];
        menu.triggered.connect(id => fired.push(id));
        // Escape inside the menu must not reach an outer handler (the
        // centers window closes on Escape).
        outerEscapes = 0;
        const button = find(menu, "overflowButton");
        compare(button.Accessible.role, Accessible.ButtonMenu);
        compare(button.Accessible.name, "More actions: Fixture");
        button.forceActiveFocus();
        keyClick(Qt.Key_Return);
        verify(menu.open);
        const popup = menu.popupItem;
        verify(popup !== null && popup.visible);
        compare(popup.Accessible.role, Accessible.PopupMenu);
        const copy = find(popup, "overflowItem_copy");
        verify(copy.activeFocus, "first enabled item gets focus");
        compare(copy.Accessible.role, Accessible.MenuItem);
        keyClick(Qt.Key_Down);
        verify(find(popup, "overflowItem_export").activeFocus);
        keyClick(Qt.Key_Down);
        verify(find(popup, "overflowItem_delete").activeFocus, "disabled items are skipped");
        const locked = find(popup, "overflowItem_locked");
        verify(locked.Accessible.name.indexOf("Not now") >= 0, "a disabled item says why");
        verify(find(popup, "overflowDangerDivider").visible, "danger action is set apart");
        compare(String(find(popup, "overflowLabel_delete").color), String(tokens.uiDanger));
        keyClick(Qt.Key_Escape);
        verify(!menu.open);
        verify(button.activeFocus, "focus returns to the menu button");
        compare(outerEscapes, 0);
        compare(fired.length, 0);
        // Space opens; Up wraps to the last enabled item; Enter fires once.
        keyClick(Qt.Key_Space);
        verify(menu.open);
        keyClick(Qt.Key_Up);
        verify(find(menu.popupItem, "overflowItem_delete").activeFocus);
        keyClick(Qt.Key_Up);
        keyClick(Qt.Key_Return);
        compare(fired, ["export"]);
        verify(!menu.open);
        // Pointer: click opens, click outside closes without firing.
        mouseClick(button);
        verify(menu.open);
        mouseClick(desktop, 20, 560);
        verify(!menu.open);
        compare(fired, ["export"]);
    }

    // ---- WindowControls ------------------------------------------------------------------
    function test_window_controls_names_keys_and_close_hover_data() {
        return ["j1", "j2", "j3"].map(style => ({ tag: style, style: style }));
    }
    function test_window_controls_names_keys_and_close_hover(row) {
        const tokens = tokensFor(row.style);
        const controls = createTemporaryObject(controlsFactory, desktop, {
            tokens: tokens, x: 600, y: 20,
            minimizeText: "Minimize", maximizeText: "Maximize", restoreText: "Restore", closeText: "Close"
        });
        const events = [];
        controls.minimizeRequested.connect(() => events.push("min"));
        controls.maximizeRequested.connect(() => events.push("max"));
        controls.closeRequested.connect(() => events.push("close"));
        waitForRendering(controls);
        const min = find(controls, "windowMinimize"), max = find(controls, "windowMaximize"), close = find(controls, "windowClose");
        for (const [bead, name] of [[min, "Minimize"], [max, "Maximize"], [close, "Close"]]) {
            compare(bead.Accessible.role, Accessible.Button);
            compare(bead.Accessible.name, name);
            verify(bead.activeFocusOnTab);
            verify(bead.width >= 24 && bead.height >= 24, "hit target ≥24 px");
        }
        controls.maximized = true;
        compare(max.Accessible.name, "Restore");
        // Symbols only on hover or keyboard focus.
        verify(!find(min, "beadGlyph").visible);
        min.forceActiveFocus();
        verify(find(min, "beadGlyph").visible, "focus shows the symbol");
        keyClick(Qt.Key_Space);
        keyClick(Qt.Key_Tab);
        verify(max.activeFocus);
        keyClick(Qt.Key_Return);
        keyClick(Qt.Key_Tab);
        verify(close.activeFocus);
        verify(Qt.colorEqual(find(close, "beadFace").fill, tokens.uiBeadCloseHot), "close turns soft red with focus");
        keyClick(Qt.Key_Enter);
        compare(events, ["min", "max", "close"]);
        close.focus = false;
        mouseMove(close, close.width / 2, close.height / 2);
        tryVerify(() => Qt.colorEqual(find(close, "beadFace").fill, tokens.uiBeadCloseHot), 500, "close turns soft red on hover");
        verify(find(min, "beadGlyph").visible, "hovering the group shows every symbol");
        mouseClick(close);
        compare(events.length, 4);
        // Beads are three different lavender shades; none is red, yellow or green at rest.
        mouseMove(desktop, 10, 590);
        tryVerify(() => !Qt.colorEqual(find(close, "beadFace").fill, tokens.uiBeadCloseHot));
        // Each bead's own shade (J3 draws it as a bubble's rim at rest).
        const fills = [min, max, close].map(b => Qt.color(b.shade));
        verify(!Qt.colorEqual(fills[0], fills[1]) && !Qt.colorEqual(fills[1], fills[2]));
        for (const fill of fills) verify(fill.hslHue > 0.66 && fill.hslHue < 0.80, "lavender hue " + fill.hslHue);
        controls.showMinimize = false;
        controls.showMaximize = false;
        verify(!min.visible && !max.visible && close.visible, "dialogs keep only close");
    }

    // ---- motion and preferences ------------------------------------------------------------
    function test_press_squash_follows_reduced_motion_data() {
        return [
            { tag: "j2-normal", style: "j2", extra: {}, animated: true },
            { tag: "j2-reduced-motion", style: "j2", extra: { reduced_motion: true }, animated: false },
            { tag: "j1-low-power", style: "j1", extra: { low_power_style: true }, animated: false }
        ];
    }
    function test_press_squash_follows_reduced_motion(row) {
        const tokens = tokensFor(row.style, row.extra);
        const button = createTemporaryObject(buttonFactory, desktop, { tokens: tokens, x: 100, y: 100 });
        waitForRendering(button);
        const face = find(button, "buttonFace");
        verify(face !== null && face.visible);
        const before = button.width;
        mousePress(button);
        if (row.animated) {
            verify(face.squashX === 1 || face.squashAnimating, "starts from rest");
            tryVerify(() => Math.abs(face.squashY - tokens.uiPressScaleY) < 0.001, 500);
        } else {
            compare(face.squashY, 1, "no squash with reduced motion / low power");
        }
        compare(button.width, before, "the hit target never scales");
        mouseRelease(button);
        tryVerify(() => face.squashY === 1, 500);
    }

    function test_legacy_button_has_no_candidate_face() {
        const button = createTemporaryObject(buttonFactory, desktop, { tokens: tokensFor("") });
        const face = find(button, "buttonFace");
        verify(face === null || !face.visible);
    }
}
