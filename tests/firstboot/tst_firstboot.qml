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
            {tag:"return", value:"abcd\refgh", ok:false}, {tag:"long", value:"a".repeat(512), ok:false},
            {tag:"511-bytes", value:"a".repeat(511), ok:true},
            {tag:"multibyte-fit", value:"😀".repeat(127) + "abc", ok:true},
            {tag:"multibyte-over", value:"😀".repeat(128), ok:false},
            {tag:"scalars-not-utf16", value:"😀".repeat(4), ok:false},
            {tag:"unicode", value:"😀".repeat(8), ok:true}, {tag:"surrogate", value:"abcdefgh\ud800", ok:false}];
    }
    function test_password(data) { compare(Validation.password(data.value), data.ok); }
    function test_display_data() {
        return [{tag:"chinese", value:"\u6797\u5c0f\u6674", ok:true}, {tag:"empty", value:"", ok:true},
            {tag:"comma", value:"a,b", ok:false}, {tag:"colon", value:"a:b", ok:false},
            {tag:"equals", value:"a=b", ok:false}, {tag:"control", value:"a\tb", ok:false},
            {tag:"format", value:"a\u202eb", ok:false},
            {tag:"zero-width", value:"a\u200bb", ok:false},
            {tag:"line-separator", value:"a\u2028b", ok:false},
            {tag:"bom", value:"a\ufeffb", ok:false},
            {tag:"long", value:"\u6797".repeat(129), ok:false}];
    }
    function test_display(data) { compare(Validation.displayName(data.value), data.ok); }
    function test_payload_cap() {
        verify(Validation.request("\u6797".repeat(128), "alice", "x".repeat(511)).length > 0);
        compare(Validation.request("\u6797".repeat(128), "alice", "😀".repeat(1024)), "");
    }
    function test_weak_is_advisory() {
        const screen = makeScreen();
        fill(screen, "12345678");
        verify(screen.weakWarning);
        verify(screen.createButton.enabled);
        screen.confirmField.text = "1234567";
        verify(!screen.createButton.enabled);
        fill(screen, "Longer-Phrase42!");
        verify(!screen.weakWarning);
        verify(screen.createButton.enabled);
        screen.phase = "creating";
        verify(!screen.createButton.enabled);
        verify(!screen.passwordField.enabled);
    }
    function test_weak_protocol_data() {
        return [{tag:"8-digits", value:"12345678", weak:true},
            {tag:"9-digits", value:"123456789", weak:true},
            {tag:"password", value:"password", weak:true},
            {tag:"password123", value:"PASSWORD123", weak:true},
            {tag:"qwerty", value:"qwerty123", weak:true},
            {tag:"letmein", value:"letmein123", weak:true},
            {tag:"bubble42", value:"bubble42!", weak:true},
            {tag:"helper-repeat", value:"aaaaaaaa", weak:true},
            {tag:"helper-chinese", value:"一二三四五六七八", weak:true},
            {tag:"helper-strong", value:"Unique-Test-Secret!42", weak:false},
            {tag:"11-mixed", value:"abcdefgh12!", weak:true},
            {tag:"12-one-class", value:"abcdefghijkl", weak:true},
            {tag:"12-two-classes", value:"abcdefghijk1", weak:false},
            {tag:"unicode-one-class", value:"\u6797".repeat(12), weak:true},
            {tag:"unicode-and-digit", value:"\u6797".repeat(11)+"1", weak:true},
            {tag:"emoji-scalars", value:"😀".repeat(6)+"12", weak:true},
            {tag:"upper-and-lower", value:"Abcdefghijkl", weak:false},
            {tag:"unicode-lower", value:"é".repeat(11)+"1", weak:false},
            {tag:"unicode-number", value:"a".repeat(11)+"²", weak:false},
            {tag:"long-phrase", value:"Longer-Phrase42!", weak:false}];
    }
    function test_weak_protocol(data) { compare(Validation.weak(data.value), data.weak); }
    function test_reserved_service_names() {
        for (const name of ["sudo", "wheel", "greetd", "ditto", "firstboot"]) verify(!Validation.username(name), name);
    }
    function test_ime_closed_on_latin_field_focus() {
        const screen = makeScreen();
        const closer = findChild(screen, "firstbootImeCloser");
        verify(closer !== null);
        compare(closer.command, ["fcitx5-remote", "-c"]);
        for (const field of [screen.usernameField, screen.passwordField, screen.confirmField]) {
            screen.displayField.focusInput();
            closer.running = false;
            const before = closer.starts;
            field.focusInput();
            compare(closer.starts, before + 1);
        }
        const input = screen.usernameField.inputItem;
        screen.usernameField.text = "";
        input.forceActiveFocus();
        keyClick("a");
        compare(input.text, "a");
        input.insert(1, "\u6797");
        compare(input.text, "a");
        keyClick("$");
        compare(input.text, "a");
    }
    function test_stopped_action_is_visible() {
        const screen = makeScreen();
        fill(screen);
        screen.phase = "stopped";
        screen.errorCode = "pam_failed";
        screen.clearSecrets();
        tryVerify(() => screen.returnButton.activeFocus);
        tryVerify(() => {
            const point = screen.returnButton.mapToItem(screen, 0, 0);
            return point.y >= 76 && point.y + screen.returnButton.height <= screen.height - 68;
        });
    }
    function test_editable_error_focuses_alert() {
        const screen = makeScreen();
        fill(screen);
        screen.createButton.forceActiveFocus();
        screen.errorCode = "username_taken";
        const alert = findChild(screen, "errorMessage");
        tryVerify(() => alert.activeFocus);
        compare(alert.Accessible.role, Accessible.AlertMessage);
    }
    function test_pam_info_is_announced_and_launch_stops_deadline() {
        const job = makeSession();
        job.session.consume('{"ok":true,"weak_password":true}');
        job.greeter.authMessage("Account notice", false, false, false);
        compare(job.session.infoMessage, "Account notice");
        const screen = makeScreen();
        screen.phase = "authenticating";
        screen.pamInfo = job.session.infoMessage;
        const live = findChild(screen, "pamInfo");
        verify(live.visible);
        compare(live.text, "Account notice");
        compare(live.Accessible.role, Accessible.AlertMessage);
        job.greeter.readyToLaunch();
        verify(!findChild(job.session, "firstbootDeadline").running);
    }
    function test_greetd_unavailable_sends_nothing() {
        const greeter = createTemporaryObject(greetdFactory, testCase, {available: false});
        const session = createTemporaryObject(sessionFactory, testCase, {greeter: greeter});
        session.submit("Alice", "alice", "bubble42!", "bubble42!");
        compare(findChild(session, "firstbootHelper").sent, "");
        const messages = createTemporaryObject(messageFactory, testCase);
        verify(messages.errorText("unavailable") !== messages.errorText("unknown"));
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
