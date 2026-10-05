import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Services.Pam
// core and i18n are symlinks to the Shell's own directories (Quickshell
// 0.3.1 does not resolve imports from outside the configuration folder).
import "core"

/// `ditto-lock`: the lock client (plan/03/04 §8.2, D-30). A Quickshell
/// configuration of its own, started by Core as its own process (`--lock`),
/// never a slot and never loaded by the ProviderHost, so no plugin update can
/// replace it (SEC-08).
///
/// The lock is the compositor's: ext_session_lock_v1 through WlSessionLock.
/// While this client runs the session is locked; if it dies, the protocol
/// keeps the session locked and shows nothing of the desktop (Wayfire's
/// behaviour there is measured separately, C-19). The password is checked by
/// PAM (Quickshell.Services.Pam), never by Ditto code.
///
/// Exit codes are the contract with Core: 0 only after a successful unlock;
/// anything else means "still locked, start another lock client". The lock
/// client does not connect to Core: it needs nothing from it.
ShellRoot {
    id: root

    property string password: ""
    property string message: ""
    property bool messageIsError: false
    property bool checking: false
    property bool unlocked: false

    function t(source) {
        return translator.t(source);
    }

    Tr {
        id: translator
        locale: Quickshell.env("DITTO_LOCALE")
            || ((Quickshell.env("LC_MESSAGES") || Quickshell.env("LANG") || "zh_TW").indexOf("en") === 0 ? "en" : "zh-TW")
    }

    function submit() {
        if (checking || password.length === 0) {
            return;
        }
        checking = true;
        messageIsError = false;
        message = t(qsTr("正在確認密碼…"));
        pam.start();
    }

    PamContext {
        id: pam
        config: Quickshell.env("DITTO_LOCK_PAM_SERVICE") || "login"

        onPamMessage: {
            if (responseRequired) {
                respond(root.password);
            } else if (messageIsError) {
                root.messageIsError = true;
                root.message = message;
            }
        }

        onCompleted: result => {
            root.checking = false;
            root.password = "";
            if (result === PamResult.Success) {
                root.unlocked = true;
                root.message = root.t(qsTr("已解鎖"));
                lock.locked = false;
                // Let the unlock request reach the compositor, then exit 0:
                // Core reads exit 0 as "unlocked".
                exitTimer.start();
            } else {
                root.messageIsError = true;
                root.message = root.t(qsTr("密碼不正確，請再試一次"));
            }
        }

        onError: error => {
            root.checking = false;
            root.password = "";
            root.messageIsError = true;
            root.message = root.t(qsTr("無法確認密碼（系統驗證服務沒有回應），請再試一次"));
            console.log("ditto-lock pam error " + error);
        }
    }

    Timer {
        id: exitTimer
        interval: 150
        onTriggered: Qt.exit(0)
    }

    /// The compositor must confirm the lock; without that this client is not
    /// protecting anything, and Core should start another one.
    Timer {
        interval: 5000
        running: !lock.secure && !root.unlocked
        onTriggered: {
            console.log("ditto-lock the compositor did not confirm the lock");
            Qt.exit(2);
        }
    }

    WlSessionLock {
        id: lock
        locked: true

        onSecureChanged: {
            if (secure) {
                console.log("ditto-lock locked");
            }
        }

        onLockedChanged: {
            if (!locked && !root.unlocked) {
                // The compositor ended the lock without our unlock.
                console.log("ditto-lock lost the lock");
                Qt.exit(3);
            }
        }

        WlSessionLockSurface {
            id: surface
            color: "#12121a"

            SystemClock {
                id: clock
                precision: SystemClock.Minutes
            }

            Column {
                anchors.centerIn: parent
                spacing: 18
                width: 360

                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: Qt.formatDateTime(clock.date, "HH:mm")
                    color: "#f2f3f8"
                    font.pixelSize: 64
                    font.weight: Font.Light
                }

                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: root.t(qsTr("已鎖定"))
                    color: "#a9aec4"
                    font.pixelSize: 16
                    Accessible.role: Accessible.StaticText
                    Accessible.name: text
                }

                Rectangle {
                    width: parent.width
                    height: 44
                    radius: 12
                    color: "#1d1f2b"
                    border.color: input.activeFocus ? "#f2f3f8" : "#5a6180"
                    border.width: input.activeFocus ? 2 : 1

                    TextInput {
                        id: input
                        anchors.fill: parent
                        anchors.leftMargin: 14
                        anchors.rightMargin: 14
                        verticalAlignment: TextInput.AlignVCenter
                        echoMode: TextInput.Password
                        passwordCharacter: "●"
                        color: "#f2f3f8"
                        font.pixelSize: 16
                        focus: true
                        enabled: !root.checking && !root.unlocked
                        text: root.password
                        onTextEdited: root.password = text
                        onAccepted: root.submit()
                        Accessible.role: Accessible.EditableText
                        Accessible.name: root.t(qsTr("密碼"))
                        Accessible.passwordEdit: true
                        Component.onCompleted: forceActiveFocus()

                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            visible: input.text.length === 0
                            text: root.t(qsTr("輸入密碼後按 Enter 解鎖"))
                            color: "#a9aec4"
                            font.pixelSize: 14
                        }
                    }
                }

                Text {
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                    visible: text.length > 0
                    text: root.message
                    color: root.messageIsError ? "#ffcf8b" : "#a9aec4"
                    font.pixelSize: 14
                    Accessible.role: Accessible.AlertMessage
                    Accessible.name: text
                }
            }
        }
    }
}
