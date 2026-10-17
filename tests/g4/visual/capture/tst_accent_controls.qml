import QtQuick
import QtTest
import "../../../../shell/jelly" as Jelly
import "../../../../shell/ui" as Ui

// Real controls with labelled fixture text, for the intentional #72 colour
// change. Offscreen development evidence; no Core or compositor involved.
TestCase {
    name: "CaptureAccentControls"
    width: 800
    height: 240
    visible: true
    when: windowShown
    Jelly.Tokens { id: tokens }
    Rectangle {
        id: scene
        width: 800; height: 240
        color: tokens.background
        Column {
            x: 24; y: 24; spacing: 16
            Text { text: "Fixture: primary / danger / badges / selected choice / checked toggle"; color: tokens.foreground }
            Row {
                spacing: 16
                Ui.Button { tokens: tokens; text: "Primary"; kind: "primary" }
                Ui.Button { tokens: tokens; text: "Danger"; kind: "danger" }
                Repeater {
                    model: ["info", "good", "warn", "bad"]
                    Ui.Badge { required property string modelData; tokens: tokens; text: modelData; tone: modelData }
                }
            }
            Ui.Choice { tokens: tokens; options: [{value: "selected", label: "Selected"}]; value: "selected" }
            Ui.Toggle { tokens: tokens; checked: true; text: "Enabled" }
        }
    }
    function test_capture() {
        for (const theme of ["no-theme", "soft-jelly", "soft-jelly-light"]) {
            tokens.appearance = theme === "no-theme" ? { tokens: {} } : { theme: theme, tokens: {} };
            waitForRendering(scene);
            grabImage(scene).save(Qt.resolvedUrl("../.staged/out/accent-controls-" + theme + ".png").toString().replace("file://", ""));
        }
    }
}
