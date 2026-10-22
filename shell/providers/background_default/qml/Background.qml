import QtQuick
import Quickshell
import Quickshell.Wayland
import "root:/sdk/Ditto/Ui"

Scope {
    id: provider
    required property var client
    required property var tokens
    required property var config
    required property var screen
    required property string slotName
    required property string entryId
    required property bool shown
    readonly property string reservedEdge: "none"
    readonly property bool ready: true
    function healthy() { return true; }
    function release() { shown = false; }

    Variants {
        model: Quickshell.screens
        PanelWindow {
            required property var modelData
            screen: modelData
            anchors { top: true; bottom: true; left: true; right: true }
            visible: provider.shown
            exclusionMode: ExclusionMode.Ignore
            exclusiveZone: 0
            aboveWindows: false
            color: provider.tokens.background
            mask: Region {}
            WlrLayershell.layer: WlrLayer.Background
            WlrLayershell.namespace: "ditto-background-provider"
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
            Backdrop {
                anchors.fill: parent
                tokens: provider.tokens
                wallpaperSource: provider.tokens.wallpaper
            }
        }
    }
}
