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
    Jelly.Tokens { id: sceneTokens }
    Rectangle {
        id: scene
        width: 800; height: 240
        color: sceneTokens.background
        Column {
            x: 24; y: 24; spacing: 16
            Text { text: "Fixture: primary / danger / badges / selected choice / checked toggle"; color: sceneTokens.foreground }
            Row {
                spacing: 16
                Ui.Button { tokens: sceneTokens; text: "Primary"; kind: "primary" }
                Ui.Button { tokens: sceneTokens; text: "Danger"; kind: "danger" }
                Repeater {
                    model: ["info", "good", "warn", "bad"]
                    Ui.Badge { required property string modelData; objectName: "badge_" + modelData; tokens: sceneTokens; text: modelData; tone: modelData }
                }
            }
            Ui.Choice { tokens: sceneTokens; options: [{value: "selected", label: "Selected"}]; value: "selected" }
            Ui.Toggle { tokens: sceneTokens; checked: true; text: "Enabled" }
        }
    }
    function test_capture() {
        for (const theme of ["no-theme", "soft-jelly", "soft-jelly-light"]) {
            sceneTokens.appearance = theme === "no-theme" ? { tokens: {} } : { theme: theme, tokens: {} };
            for (const tone of ["info", "good", "warn", "bad"]) {
                verify(findChild(scene, "badge_" + tone).width > 0, tone + " badge rendered");
            }
            waitForRendering(scene);
            grabImage(scene).save(Qt.resolvedUrl("../.staged/out/accent-controls-" + theme + ".png").toString().replace("file://", ""));
        }
    }
}
