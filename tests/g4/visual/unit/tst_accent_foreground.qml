import QtQuick
import QtTest
import "../../../../shell/jelly" as Jelly

// Actual Tokens bindings, with ../stubs replacing Quickshell. The Profile's
// wire key remains on_accent; each row also exercises a live projection update.
TestCase {
    id: testCase
    name: "AccentForeground"
    Component { id: tokensFactory; Jelly.Tokens {} }

    function test_profile_foreground_data() {
        return [
            { tag: "no-theme", appearance: { tokens: {} }, expected: "#1a1626" },
            { tag: "soft-jelly", appearance: { theme: "soft-jelly", tokens: {} }, expected: "#1a1626" },
            { tag: "soft-jelly-light", appearance: { theme: "soft-jelly-light", tokens: {} }, expected: "#1c1830" }
        ];
    }

    function test_profile_foreground(row) {
        const tokens = createTemporaryObject(tokensFactory, testCase, { appearance: row.appearance });
        compare(String(tokens.accentForeground), row.expected, "recipe default");
        tokens.appearance = Object.assign({}, row.appearance, { tokens: { on_accent: "invalid" } });
        compare(String(tokens.accentForeground), row.expected, "invalid override falls back");
        tokens.appearance = row.appearance;
        compare(String(tokens.accentForeground), row.expected, "removing override restores recipe");
    }

    function test_profile_override_data() { return test_profile_foreground_data(); }

    function test_profile_override(row) {
        const tokens = createTemporaryObject(tokensFactory, testCase, {
            appearance: Object.assign({}, row.appearance, { tokens: { on_accent: "#ff0000" } })
        });
        compare(String(tokens.accentForeground), "#ff0000", "initial Profile override");
        tokens.appearance = Object.assign({}, row.appearance, { tokens: { on_accent: "#00ff00" } });
        compare(String(tokens.accentForeground), "#00ff00", "live Profile override");
    }

    function test_before_projection() {
        const tokens = createTemporaryObject(tokensFactory, testCase);
        compare(String(tokens.accentForeground), "#1a1626");
    }
}
