import QtQuick
import QtTest
import DittoStub
import "../../../../shell/jelly" as Jelly
import "../../../../shell/ui" as Ui
import "../../../../shell/avatar" as Avatar

// Read the actual foreground and fill of each status consumer, rather than
// inferring that the consumer uses the right token. Quickshell is stubbed.
TestCase {
    id: testCase
    name: "StatusFillContrast"
    width: 800; height: 240
    visible: true
    when: windowShown
    Item { id: desktop; width: 800; height: 240 }
    Component { id: tokenFactory; Jelly.Tokens {} }
    Component { id: buttonFactory; Ui.Button { text: "Fixture" } }
    Component { id: badgeFactory; Ui.Badge { text: "Fixture" } }
    Component { id: avatarFactory; Avatar.Avatar { avatarState: "awaiting"; animations: false } }
    QtObject {
        id: client
        property var tasks: ({ demo: true, tasks: [] })
        property string tasksStatus: "available"
        property string mode: "normal"
        function t(text) { return text; }
        function watchTasks() {}
        function unwatchTasks() {}
    }

    function contrast(a, b) {
        const linear = c => c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4);
        const luminance = c => 0.2126 * linear(c.r) + 0.7152 * linear(c.g) + 0.0722 * linear(c.b);
        const la = luminance(a), lb = luminance(b);
        return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05);
    }

    function label(root, text) {
        for (const child of root.children) {
            if (child.text === text && child.color !== undefined) return child;
            const found = label(child, text);
            if (found) return found;
        }
        return null;
    }

    // Avatar remains an ordinary assertion: this lane forbids writes to
    // shell/avatar/**, so a failure there must stay visible until repaired.
    function test_fill_pairs_data() {
        const rows = [];
        for (const theme of ["no-theme", "soft-jelly", "soft-jelly-light"]) {
            for (const mode of ["normal", "reduced-transparency", "low-power"]) {
                for (const pair of ["Button.danger", "Badge.good", "Badge.warn", "Badge.bad", "TasksPanel.demo",
                                    "Button.primary", "Badge.info", "Badge.neutral", "Button.secondary", "Avatar.awaiting"]) {
                    rows.push({ tag: theme + "/" + mode + "/" + pair, theme: theme, mode: mode, pair: pair });
                }
            }
        }
        return rows;
    }

    function test_accent_override_keeps_status_foreground() {
        const tokens = createTemporaryObject(tokenFactory, testCase, {
            appearance: { theme: "soft-jelly-light", tokens: { on_accent: "#ff0000" } }
        });
        const status = createTemporaryObject(badgeFactory, desktop, { tokens: tokens, tone: "good" });
        const accent = createTemporaryObject(badgeFactory, desktop, { tokens: tokens, tone: "info" });
        compare(String(label(status, "Fixture").color), "#ffffff");
        compare(String(label(accent, "Fixture").color), "#ff0000");
    }

    function test_fill_pairs(row) {
        failOnWarning(/./);
        StubDesktop.layer = desktop;
        const appearance = { tokens: {}, reduced_transparency: row.mode === "reduced-transparency", low_power_style: row.mode === "low-power" };
        if (row.theme !== "no-theme") appearance.theme = row.theme;
        const tokens = createTemporaryObject(tokenFactory, testCase, { appearance: appearance });
        let root, text;
        if (row.pair === "TasksPanel.demo") {
            const component = Qt.createComponent(Qt.resolvedUrl("../.staged/providers/TasksPanel.qml"));
            verify(component.status === Component.Ready, component.errorString());
            root = createTemporaryObject(component, testCase, { tokens: tokens, client: client, shown: true });
            text = label(desktop, "示範資料");
        } else if (row.pair === "Avatar.awaiting") {
            root = createTemporaryObject(avatarFactory, desktop, { tokens: tokens });
            text = label(root, "?");
        } else {
            const parts = row.pair.split(".");
            const properties = { tokens: tokens };
            properties[parts[0] === "Button" ? "kind" : "tone"] = parts[1];
            root = createTemporaryObject(parts[0] === "Button" ? buttonFactory : badgeFactory, desktop, properties);
            text = label(root, "Fixture");
        }
        verify(text !== null, row.tag + ": rendered label");
        const ratio = contrast(text.color, text.parent.color);
        console.log("CONTRAST " + [row.tag, String(text.color), String(text.parent.color), ratio.toFixed(2), 4.5].join(" "));
        if (root.release) root.release();
        verify(ratio >= 4.5, row.tag + ": text/fill " + ratio.toFixed(2));
    }
}
