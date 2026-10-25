pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Wayland
import "core"

// Independent configuration; ordinary desktop providers cannot replace it.
ShellRoot {
    id: root
    Tr {
        id: tr
        locale: Quickshell.env("DITTO_LOCALE") || "zh-TW"
    }
    AccountSession {
        id: account
        onClearSecrets: screen.clearSecrets()
    }
    PanelWindow {
        anchors { top: true; bottom: true; left: true; right: true }
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
        WlrLayershell.namespace: "ditto-firstboot"
        color: "#d3cff9"
        FirstbootScreen {
            id: screen
            anchors.fill: parent
            translator: tr
            phase: account.phase
            errorCode: account.errorCode
            pamInfo: account.infoMessage
            onSubmitted: (displayName, username, password, confirm) => account.submit(displayName, username, password, confirm)
            onReturnToLogin: Qt.exit(10)
        }
    }
}
