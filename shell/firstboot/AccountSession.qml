pragma ComponentBehavior: Bound
import QtQuick
import Quickshell.Io
import Quickshell.Services.Greetd
import "Validation.js" as Validation

// One attempt, no reconnect/replay. Secrets live only in memory; no logging.
Item {
    id: session
    property var greeter: Greetd
    property string phase: "editing"
    property string errorCode: ""
    property string username: ""
    property string password: ""
    property string pendingRequest: ""
    property string response: ""
    property bool responded: false
    property bool weakPassword: false
    readonly property bool busy: phase === "creating" || phase === "authenticating" || phase === "launching"
    readonly property bool canEdit: phase === "editing"
    signal clearSecrets()

    function forgetSecrets() {
        password = "";
        pendingRequest = "";
        clearSecrets();
    }
    function fail(code, editable) {
        phase = editable ? "editing" : "stopped";
        errorCode = code;
        deadline.stop();
        helper.connected = false;
        forgetSecrets();
    }
    function submit(display, name, secret, confirm) {
        if (!canEdit || !Validation.valid(display, name, secret, confirm)) return;
        if (!greeter.available) { fail("unavailable", false); return; }
        username = name;
        password = secret;
        pendingRequest = Validation.request(display, name, secret);
        response = "";
        responded = false;
        errorCode = "";
        phase = "creating";
        clearSecrets();
        deadline.start();
        helper.connected = true;
    }
    function consume(data) {
        if (phase !== "creating") return;
        response += data;
        if (response.length > 4096) { fail("unknown", false); return; }
        let reply;
        try { reply = JSON.parse(response); } catch (e) { return; }
        response = "";
        if (reply.ok === true && typeof reply.weak_password === "boolean") {
            weakPassword = reply.weak_password;
            phase = "authenticating";
            helper.connected = false;
            deadline.restart();
            greeter.createSession(username);
        } else if (reply.ok === false && typeof reply.error === "string") {
            const editable = ["invalid_username", "username_taken", "password_too_short", "password_invalid",
                "display_name_invalid", "internal_rolled_back"].indexOf(reply.error) >= 0;
            fail(reply.error, editable);
        } else fail("unknown", false);
    }
    function authMessage(message, error, responseRequired, echoResponse) {
        // Never echo the password or send it to an unexpected second challenge.
        if (phase !== "authenticating") return;
        if (error || (responseRequired && (echoResponse || responded))) { authFailed(); return; }
        if (responseRequired) {
            responded = true;
            greeter.respond(password);
            password = "";
        }
    }
    function authFailed() {
        if (phase !== "authenticating" && phase !== "launching") return;
        fail("pam_failed", false);
        greeter.cancelSession();
    }
    function launch() {
        if (phase !== "authenticating") return;
        phase = "launching";
        forgetSecrets();
        greeter.launch(["/usr/local/libexec/ditto-image-session"]);
    }
    Socket {
        id: helper
        objectName: "firstbootHelper"
        path: "/run/ditto/firstboot-account.sock"
        onConnectionStateChanged: {
            if (connected && session.phase === "creating") {
                write(session.pendingRequest);
                flush();
                session.pendingRequest = "";
            } else if (!connected && session.phase === "creating") session.fail("unknown", false);
        }
        onError: () => { if (session.phase === "creating") session.fail("unknown", false); }
        // Raw chunks: accept complete JSON with or without a trailing newline.
        parser: SplitParser { splitMarker: ""; onRead: data => session.consume(data) }
    }
    Timer {
        id: deadline
        objectName: "firstbootDeadline"
        interval: 60000
        onTriggered: {
            if (session.phase === "creating") session.fail("unknown", false);
            else session.authFailed();
        }
    }
    Connections {
        target: session.greeter
        function onAuthMessage(message, error, responseRequired, echoResponse) {
            session.authMessage(message, error, responseRequired, echoResponse);
        }
        function onAuthFailure(_message) { session.authFailed(); }
        function onError(_error) { session.authFailed(); }
        function onReadyToLaunch() { session.launch(); }
    }
    Component.onDestruction: forgetSecrets()
}
