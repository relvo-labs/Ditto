import QtQuick
import QtTest
import "../../shell/firstboot" as Firstboot
import "../../shell/firstboot/Validation.js" as Validation

TestCase {
    id: testCase
    name: "Firstboot"
    width: 1280; height: 720
    visible: true
    when: windowShown
    QtObject { id: testTranslator; function t(source) { return source; } }
    Component { id: screenFactory; Firstboot.FirstbootScreen { translator: testTranslator } }
    Component { id: sessionFactory; Firstboot.AccountSession {} }
    Component { id: messageFactory; Firstboot.Messages {} }
    Component {
        id: greetdFactory
        QtObject {
            property bool available: true
            property string user: ""
            property string answer: ""
            property int prompts: 0
            property int cancellations: 0
            property var command: []
            signal authMessage(string message, bool error, bool responseRequired, bool echoResponse)
            signal authFailure(string message)
            signal error(string error)
            signal readyToLaunch()
            function createSession(name) { user = name; }
            function respond(secret) { answer = secret; ++prompts; }
            function cancelSession() { ++cancellations; }
            function launch(argv) { command = argv; }
        }
    }
    function makeScreen() { return createTemporaryObject(screenFactory, testCase, {width: 1280, height: 720}); }
    function fill(screen, secret) {
        screen.displayField.text = "\u6797\u5c0f\u6674";
        screen.usernameField.text = "hsiaoching";
        screen.passwordField.text = secret || "bubble42!";
        screen.confirmField.text = secret || "bubble42!";
    }
    function test_username_data() {
        return [{tag:"lower", value:"hsiao-42", ok:true}, {tag:"upper", value:"Hsiao", ok:false},
            {tag:"digit", value:"1abc", ok:false}, {tag:"dollar", value:"a$", ok:false},
            {tag:"reserved", value:"root", ok:false}, {tag:"space", value:"a b", ok:false},
            {tag:"31", value:"a".repeat(31), ok:true}, {tag:"32", value:"a".repeat(32), ok:false}];
    }
    function test_username(data) { compare(Validation.username(data.value), data.ok); }
    function test_password_data() {
        return [{tag:"7", value:"1234567", ok:false}, {tag:"8", value:"12345678", ok:true},
            {tag:"nul", value:"abcd\x00efgh", ok:false}, {tag:"newline", value:"abcd\nefgh", ok:false},
            {tag:"return", value:"abcd\refgh", ok:false}, {tag:"long", value:"a".repeat(1025), ok:false},
            {tag:"unicode", value:"😀".repeat(8), ok:true}, {tag:"surrogate", value:"abcdefgh\ud800", ok:false}];
    }
    function test_password(data) { compare(Validation.password(data.value), data.ok); }
    function test_display_data() {
        return [{tag:"chinese", value:"\u6797\u5c0f\u6674", ok:true}, {tag:"empty", value:"", ok:true},
            {tag:"comma", value:"a,b", ok:false}, {tag:"colon", value:"a:b", ok:false},
            {tag:"equals", value:"a=b", ok:false}, {tag:"control", value:"a\tb", ok:false},
            {tag:"long", value:"\u6797".repeat(129), ok:false}];
    }
    function test_display(data) { compare(Validation.displayName(data.value), data.ok); }
    function test_payload_cap() {
        verify(Validation.request("\u6797".repeat(128), "alice", "x".repeat(1024)).length > 0);
        compare(Validation.request("\u6797".repeat(128), "alice", "😀".repeat(1024)), "");
    }
    function test_weak_is_advisory() {
        const screen = makeScreen();
        fill(screen, "12345678");
        verify(screen.weakWarning);
        verify(screen.createButton.enabled);
        screen.confirmField.text = "1234567";
        verify(!screen.createButton.enabled);
        fill(screen, "bubble42!");
        verify(!screen.weakWarning);
        verify(screen.createButton.enabled);
        screen.phase = "creating";
        verify(!screen.createButton.enabled);
        verify(!screen.passwordField.enabled);
    }
    function test_errors_data() {
        return ["invalid_username", "username_taken", "password_too_short", "password_invalid", "display_name_invalid",
            "already_provisioned", "unauthorized", "internal_rolled_back", "internal_rollback_failed", "pam_failed", "unknown"]
            .map(code => ({tag:code, code:code}));
    }
    function test_errors(data) {
        const messages = createTemporaryObject(messageFactory, testCase);
        const text = messages.errorText(data.code);
        verify(/[\u3400-\u9fff]/.test(text));
        verify(text.indexOf(data.code) < 0);
        const screen = makeScreen();
        screen.errorCode = data.code;
        const alert = findChild(screen, "errorMessage");
        compare(alert.text, text);
        compare(alert.Accessible.role, Accessible.AlertMessage);
        compare(alert.Accessible.name, text);
    }
    function test_accessibility_and_input_method() {
        const screen = makeScreen();
        for (const field of [screen.displayField, screen.usernameField, screen.passwordField, screen.confirmField]) {
            compare(field.inputItem.Accessible.role, Accessible.EditableText);
            // Qt 6.10 suppresses TextInput.Password's direct Accessible.name
            // getter; use an explicit label relation (Orca still needs VM).
            compare(field.inputItem.Accessible.labelledBy.Accessible.name, field.accessibleName);
            if (!field.secret) compare(field.inputItem.Accessible.name, field.accessibleName);
            verify(field.inputItem.Accessible.description.length > 0);
        }
        compare(screen.passwordField.inputItem.Accessible.passwordEdit, true);
        compare(screen.confirmField.inputItem.Accessible.passwordEdit, true);
        verify(!(screen.displayField.inputMethodHints & Qt.ImhLatinOnly));
        for (const field of [screen.usernameField, screen.passwordField, screen.confirmField]) {
            verify(field.inputMethodHints & Qt.ImhLatinOnly);
            verify(field.inputMethodHints & Qt.ImhNoPredictiveText);
        }
        for (const button of [screen.createButton, screen.returnButton]) {
            compare(button.Accessible.role, Accessible.Button);
            verify(button.Accessible.name.length > 0);
            verify(button.Accessible.description.length > 0);
        }
    }
    function test_tab_order() {
        const screen = makeScreen();
        fill(screen);
        const order = [screen.displayField.inputItem, screen.usernameField.inputItem,
            screen.passwordField.inputItem, screen.confirmField.inputItem, screen.createButton];
        screen.visible = true;
        order[0].forceActiveFocus();
        wait(10);
        for (let i = 1; i <= order.length; ++i) {
            keyClick(Qt.Key_Tab);
            verify(order[i % order.length].activeFocus, "forward " + i + " focused=" + order.map(item => item.activeFocus));
        }
        for (let i = order.length - 1; i >= 0; --i) {
            keyClick(Qt.Key_Backtab);
            verify(order[i].activeFocus, "reverse " + i + " focused=" + order.map(item => item.activeFocus));
        }
        screen.confirmField.text = "bad";
        screen.confirmField.inputItem.forceActiveFocus();
        keyClick(Qt.Key_Tab);
        verify(screen.displayField.inputItem.activeFocus);
    }
    function makeSession() {
        const greeter = createTemporaryObject(greetdFactory, testCase);
        const session = createTemporaryObject(sessionFactory, testCase, {greeter: greeter});
        session.submit("Alice", "alice", "bubble42!", "bubble42!");
        compare(session.phase, "creating");
        return {session: session, greeter: greeter};
    }
    function test_helper_then_pam_then_launch() {
        const job = makeSession();
        job.session.consume('{"ok":tr');
        compare(job.greeter.user, "");
        job.session.consume('ue,"weak_password":false}\n');
        compare(job.session.phase, "authenticating");
        compare(job.greeter.user, "alice");
        job.greeter.authMessage("Password:", false, true, false);
        compare(job.greeter.answer, "bubble42!");
        compare(job.session.password, "");
        job.greeter.readyToLaunch();
        compare(job.session.phase, "launching");
        compare(job.greeter.command, ["/usr/local/libexec/ditto-image-session"]);
    }
    function test_no_password_replay_or_echo() {
        for (const echo of [false, true]) {
            const job = makeSession();
            job.session.consume('{"ok":true,"weak_password":true}');
            job.greeter.authMessage("Challenge", false, true, echo);
            job.greeter.authMessage("Again", false, true, false);
            compare(job.session.errorCode, "pam_failed");
            compare(job.session.phase, "stopped");
            compare(job.session.password, "");
            compare(job.greeter.prompts, echo ? 0 : 1);
            compare(job.greeter.cancellations, 1);
        }
    }
    function test_transport_loss_never_replays() {
        const job = makeSession();
        const socket = findChild(job.session, "firstbootHelper");
        const request = JSON.parse(socket.sent);
        compare(request.username, "alice");
        compare(request.password, "bubble42!");
        compare(job.session.pendingRequest, "");
        socket.connected = false;
        compare(job.session.phase, "stopped");
        compare(job.session.errorCode, "unknown");
        compare(job.session.password, "");
        job.session.submit("Alice", "alice", "bubble42!", "bubble42!");
        compare(socket.sent.trim().split("\n").length, 1);
    }
    function test_deadline_clears_password() {
        const job = makeSession();
        findChild(job.session, "firstbootDeadline").triggered();
        compare(job.session.phase, "stopped");
        compare(job.session.errorCode, "unknown");
        compare(job.session.password, "");
    }
    function test_pam_failure_cannot_launch() {
        const job = makeSession();
        job.session.consume('{"ok":true,"weak_password":false}');
        job.greeter.authFailure("private PAM text is never shown");
        job.greeter.readyToLaunch();
        compare(job.session.phase, "stopped");
        compare(job.session.errorCode, "pam_failed");
        compare(job.greeter.command, []);
    }
    function test_helper_error_and_unknown() {
        const job = makeSession();
        job.session.consume('{"ok":false,"error":"internal_rolled_back"}');
        compare(job.session.phase, "editing");
        compare(job.session.password, "");
        const unknown = makeSession();
        unknown.session.consume('{"ok":true}');
        compare(unknown.session.phase, "stopped");
        compare(unknown.session.errorCode, "unknown");
        compare(unknown.session.password, "");
    }
}
