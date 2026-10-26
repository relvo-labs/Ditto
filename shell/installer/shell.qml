pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Wayland
import "core"

// Independent configuration for the #221 installer image; runs as the
// unprivileged ditto-installer user and talks only to the root backend socket.
ShellRoot {
    id: root
    Tr {
        id: tr
        locale: "zh-TW"
    }
    InstallerClient { id: backend }
    PanelWindow {
        anchors { top: true; bottom: true; left: true; right: true }
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
        WlrLayershell.namespace: "ditto-installer"
        color: "#d3cff9"
        InstallerScreen {
            anchors.fill: parent
            translator: tr
            client: backend
        }
    }
}
