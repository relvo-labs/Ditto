import QtQuick
import Quickshell

/// C-07 fixture. One layer surface, 200x200 at the top-left corner, whose input
/// region covers only the 100x100 square at its origin. The rest of the surface
/// is transparent *and* outside the input region, which is the combination a
/// click has to pass through. The same mechanism the character layer uses
/// (`mask: Region`), reduced to one rectangle so the expected result is exact.
ShellRoot {
    PanelWindow {
        anchors { top: true; left: true }
        implicitWidth: 200
        implicitHeight: 200
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        focusable: false
        aboveWindows: true

        mask: Region {
            x: 0
            y: 0
            width: 100
            height: 100
        }

        Rectangle {
            x: 0
            y: 0
            width: 100
            height: 100
            color: "#8022d3ee"

            MouseArea {
                anchors.fill: parent
                onPressed: console.log("C07_HIT")
            }
        }

        Component.onCompleted: console.log("C07_READY")
    }
}
