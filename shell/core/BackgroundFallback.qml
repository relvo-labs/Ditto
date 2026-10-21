import QtQuick
import Quickshell
import Quickshell.Wayland
import "../jelly"

/// Trusted compatibility background; never reported as a loaded package.
Scope {
    id: fallback
    required property var providers
    required property var tokens
    readonly property bool shown: !providers.backgroundShown
    Variants {
        model: Quickshell.screens

        PanelWindow {
            required property var modelData
            screen: modelData
            anchors { top: true; bottom: true; left: true; right: true }
            exclusionMode: ExclusionMode.Ignore
            aboveWindows: false
            color: fallback.tokens.background
            WlrLayershell.layer: WlrLayer.Background
            WlrLayershell.namespace: "ditto-background"
            visible: fallback.shown
            mask: Region {}
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

            /// The canvas, with the light recipe's default wallpaper on top
            /// once it has loaded. A per-Profile wallpaper field is still
            /// Core's (docs/design/default-desktop/component-sheet.md H2).
            Backdrop {
                anchors.fill: parent
                tokens: fallback.tokens
                wallpaperSource: fallback.tokens.wallpaper
            }
        }
    }
}
