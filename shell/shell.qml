import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import "core"
import "jelly"
import "avatar"
import "providers/panel_top"
import "providers/dock_bottom"

/// Ditto's G0 session: background, top panel, dock and the character layer.
/// The desktop state all comes through Core; the character does not depend on
/// it, and the shell writes nothing to disk.
ShellRoot {
    id: root

    Tokens {
        id: tokens
        reducedMotion: Quickshell.env("DITTO_REDUCED_MOTION") === "1"
        reducedTransparency: Quickshell.env("DITTO_REDUCED_TRANSPARENCY") === "1"
    }

    RpcCounter {
        id: rpcCounter
    }

    DittoClient {
        id: client
        counter: rpcCounter
    }

    Variants {
        model: Quickshell.screens

        PanelWindow {
            required property var modelData
            screen: modelData
            anchors { top: true; bottom: true; left: true; right: true }
            exclusionMode: ExclusionMode.Ignore
            aboveWindows: false
            color: tokens.background
            WlrLayershell.layer: WlrLayer.Background
        }
    }

    PanelTop {
        tokens: tokens
        client: client
    }

    DockBottom {
        tokens: tokens
        client: client
    }

    PanelWindow {
        id: avatarSurface

        anchors { bottom: true; right: true }
        margins { bottom: 64; right: 32 }
        implicitWidth: 220
        implicitHeight: 250
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        focusable: false
        aboveWindows: true

        /// Built from the alpha channel at build time. Without it the
        /// transparent area would swallow clicks meant for the application
        /// underneath.
        mask: Region {
            id: hitRegion
            intersection: Intersection.Combine
        }

        Avatar {
            id: avatar
            anchors.top: parent.top
            anchors.horizontalCenter: parent.horizontalCenter
            width: parent.width
            height: parent.width
            tokens: tokens
        }

        /// The character's state is readable as text from the first day, so the
        /// states added later cannot arrive without their wording.
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            color: tokens.foreground
            font.pixelSize: tokens.fontSmall
            text: avatar.stateText
            Accessible.role: Accessible.StaticText
            Accessible.name: avatar.stateText
        }

        FrameProbe {}

        /// The mask file is read once at startup, from the shell's own
        /// directory; the shell reads no other file and writes none.
        FileView {
            id: maskFile
            path: Qt.resolvedUrl("avatar/layers/hit-mask.json").toString().replace("file://", "")
            blockLoading: true
        }

        Component.onCompleted: {
            const mask = JSON.parse(maskFile.text());
            const component = Qt.createComponent(Qt.resolvedUrl("avatar/MaskRegion.qml"));
            const regions = [];
            for (const rectangle of mask.rectangles) {
                regions.push(component.createObject(hitRegion, {
                    x: Math.round(rectangle.x * avatar.width),
                    y: Math.round(rectangle.y * avatar.height),
                    width: Math.max(1, Math.round(rectangle.width * avatar.width)),
                    height: Math.max(1, Math.round(rectangle.height * avatar.height))
                }));
            }
            hitRegion.regions = regions;
            console.log("ditto-shell hit mask rectangles=" + regions.length);
        }
    }

    /// The shell's control path: the compositor's keybindings write one line
    /// here, and so does the verification script. `workspace` takes exactly the
    /// same route as a click on the panel, which is what makes the request
    /// count per explicit command measurable.
    SocketServer {
        active: true
        path: (Quickshell.env("DITTO_RUNTIME_DIR")
            || ((Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/ditto")) + "/shell.sock"
        handler: Socket {
            parser: SplitParser {
                splitMarker: "\n"
                onRead: line => {
                    const command = line.trim().split(" ");
                    if (command[0] === "recall") {
                        avatarSurface.visible = true;
                        avatarSurface.aboveWindows = true;
                        console.log("ditto-shell avatar recalled");
                    } else if (command[0] === "workspace" && command.length === 2) {
                        client.activateWorkspace(command[1]);
                    } else {
                        console.log("ditto-shell ignored control line");
                    }
                }
            }
        }
    }

    Component.onCompleted: console.log("ditto-shell started")
}
