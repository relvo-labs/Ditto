import QtQuick
import Quickshell

ShellRoot {
    PanelWindow {
        anchors {
            top: true
            left: true
            right: true
        }

        implicitHeight: 36
        exclusiveZone: 36
        color: "#253447"

        Text {
            anchors.centerIn: parent
            text: "Ditto Wayland development test"
            color: "white"
        }
    }
}
