import QtQuick
import QtTest
import "../../shell/ui" as Ui
import "../../shell/jelly" as Jelly
TestCase {
    id: suite
    name: "TextFieldCompatibility"
    width: 400; height: 200; visible: true
    when: windowShown
    Jelly.Tokens { id: compatTokens; readsSystemPreference: false }
    Text { id: label; text: "API key"; Accessible.name: text }
    Component { id: ordinary; Ui.TextField { tokens: compatTokens; accessibleName: "Existing field" } }
    Component { id: secret; Ui.TextField { tokens: compatTokens; accessibleName: "API key"; secret: true; accessibleLabel: label } }
    function test_default_null_label_is_safe() {
        const field = createTemporaryObject(ordinary, suite);
        verify(field !== null);
        compare(field.inputItem.Accessible.name, "Existing field");
    }
    Component { id: unlabelledSecret; Ui.TextField { tokens: compatTokens; accessibleName: "API key"; secret: true } }
    function test_existing_unlabelled_secret_keeps_name() {
        const field = createTemporaryObject(unlabelledSecret, suite);
        verify(field !== null);
        compare(field.inputItem.Accessible.name, "API key");
        field.text = "synthetic-not-a-credential";
        compare(field.inputItem.Accessible.name, "API key");
    }
    function test_existing_secret_keeps_name() {
        const field = createTemporaryObject(secret, suite);
        verify(field !== null);
        compare(field.inputItem.Accessible.name, "API key");
        field.text = "synthetic-not-a-credential";
        compare(field.inputItem.Accessible.name, "API key");
    }
}
