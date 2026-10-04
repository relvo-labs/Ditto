import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import "core"
import "jelly"
import "avatar"
import "change"
import "centers"

/// Ditto's desktop session (G1). The Shell owns what is on screen: the
/// background, the character, the four centers, the change bar, and the
/// ProviderHost that mounts the replaceable UI providers (panel, dock,
/// launcher, tasks panel, notification area) Core binds in the Profile. What
/// is configured is Core's; the Shell keeps no configuration and writes
/// nothing to disk.
ShellRoot {
    id: root

    Tr {
        id: translator
        locale: providers.appearance && providers.appearance.locale
            ? providers.appearance.locale
            : (Quickshell.env("DITTO_LOCALE") || "zh-TW")
    }

    Tokens {
        id: tokens
        appearance: providers.appearance
    }

    RpcCounter {
        id: rpcCounter
    }

    DittoClient {
        id: client
        counter: rpcCounter
        tr: translator
        participant: providers
        commandHandler: root.runCommand
    }

    ProviderHost {
        id: providers
        client: client
        tokens: tokens
        counter: rpcCounter
    }

    /// Commands the Shell owns, from `shell.command` (Core decides who owns a
    /// command; a shortcut Core bound arrives here the same way).
    /// What the `focus` control line answers: the centers' focused control
    /// by its accessible name and role, with the accessible names of the
    /// groups it sits in, innermost first. Only names are read; nothing is
    /// pressed and nothing is sent to Core.
    function focusReport() {
        const window = centersLoader.item;
        if (!centers.open || !window) {
            return { open: false };
        }
        const item = window.focusedItem;
        if (!item) {
            return { open: true, page: centers.page, focused: null };
        }
        const groups = [];
        for (let parent = item.parent; parent; parent = parent.parent) {
            const name = parent.Accessible ? parent.Accessible.name : "";
            if (name && name.length > 0) {
                groups.push(name);
            }
        }
        return {
            open: true,
            page: centers.page,
            focused: {
                name: item.Accessible ? item.Accessible.name : "",
                role: item.Accessible ? item.Accessible.role : -1,
                checked: item.Accessible ? item.Accessible.checked : false,
                enabled: item.enabled,
                groups: groups
            }
        };
    }

    /// What the `tasks` control line answers: what the mounted tasks panel
    /// (`ui.tasks_panel`) holds to show, read from the provider itself, so a
    /// verification run can tell what the panel reflects without asking Core.
    /// Read-only and on demand; nothing is sent to Core.
    function tasksReport() {
        const panel = providers.item("ui.tasks_panel");
        if (!panel) {
            return { mounted: false };
        }
        const open = panel.openTasks || [];
        return {
            mounted: true,
            shown: panel.shown === true,
            unavailable: panel.unavailable === true,
            loaded: !!panel.snapshot,
            open: open.map(task => task.text)
        };
    }

    function runCommand(commandId, args) {
        switch (commandId) {
        case "launcher.toggle": {
            const launcher = providers.item("ui.launcher");
            if (launcher && typeof launcher.toggle === "function") {
                if (!launcher.isOpen) {
                    rpcCounter.mark("launcher.open");
                }
                launcher.toggle();
            } else if (launcher && typeof launcher.open === "function") {
                launcher.isOpen ? launcher.close() : launcher.open();
            } else {
                console.log("ditto-shell no launcher is mounted");
            }
            return;
        }
        case "composition.open":
            centers.show("composition");
            return;
        case "plugins.open":
            centers.show("plugins");
            return;
        case "history.open":
            centers.show("history");
            return;
        case "personalization.open":
            centers.show("personalization");
            return;
        }
        console.log("ditto-shell ignored command " + commandId);
    }

    readonly property var shellClient: client
    readonly property var shellTokens: tokens
    readonly property var shellProviders: providers
    readonly property var avatarSettings: providers.avatar
    readonly property bool avatarEnabled: Quickshell.env("DITTO_AVATAR") !== "off"
        && (!avatarSettings || avatarSettings.enabled !== false)
    property bool avatarRecalled: false

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
            WlrLayershell.namespace: "ditto-background"
        }
    }

    /// The four centers share one window, loaded only while open: closed
    /// centers render nothing and subscribe to nothing (RUN-07).
    QtObject {
        id: centers
        property string page: "composition"
        property bool open: false

        function show(name) {
            page = name;
            open = true;
        }
    }

    LazyLoader {
        id: centersLoader
        active: centers.open

        // `client: client` here would bind the property to itself.
        Centers {
            client: root.shellClient
            tokens: root.shellTokens
            providers: root.shellProviders
            page: centers.page
            onCloseRequested: centers.open = false
            onPageChanged: centers.page = page
        }
    }

    /// Kept or cancelled here: a preview, or a change with a timed revert.
    LazyLoader {
        id: previewLoader
        active: Object.keys(client.pendingConfirmations).length > 0

        PreviewBar {
            client: root.shellClient
            tokens: root.shellTokens
        }
    }

    /// `DITTO_AVATAR=off` leaves the character out entirely: EX-05 measures the
    /// desktop with and without it, so "off" means no surface and no timers.
    /// The Profile's `avatar.enabled: false` does the same.
    LazyLoader {
        id: avatarLoader
        active: root.avatarEnabled

        PanelWindow {
            id: avatarSurface

            // Inside the loader's component, `tokens: tokens` on the Avatar
            // would bind its own property to itself; resolve the id here.
            readonly property Tokens desktopTokens: tokens
            readonly property real scale: root.avatarSettings && root.avatarSettings.scale > 0
                ? Math.max(0.5, Math.min(2.0, root.avatarSettings.scale)) : 1.0

            visible: !(root.avatarSettings && root.avatarSettings.hidden === true) || root.avatarRecalled
            anchors { bottom: true; right: true }
            margins { bottom: 64; right: 32 }
            implicitWidth: Math.round(220 * scale)
            implicitHeight: Math.round(250 * scale)
            color: "transparent"
            exclusionMode: ExclusionMode.Ignore
            focusable: false
            aboveWindows: true
            WlrLayershell.namespace: "ditto-avatar"

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
                tokens: avatarSurface.desktopTokens
                tr: translator
                animations: !root.avatarSettings || root.avatarSettings.animations !== false
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
                    // Bound, not copied: the loaded surface may not have
                    // its final size yet when this runs.
                    regions.push(component.createObject(hitRegion, {
                        x: Qt.binding(() => Math.round(rectangle.x * avatar.width)),
                        y: Qt.binding(() => Math.round(rectangle.y * avatar.height)),
                        width: Qt.binding(() => Math.max(1, Math.round(rectangle.width * avatar.width))),
                        height: Qt.binding(() => Math.max(1, Math.round(rectangle.height * avatar.height)))
                    }));
                }
                hitRegion.regions = regions;
                console.log("ditto-shell hit mask rectangles=" + regions.length);
            }
        }
    }

    /// The shell's control path: the compositor's keybindings write one line
    /// here, and so does the verification script. `workspace` takes exactly the
    /// same route as a click on the panel, which is what makes the request
    /// count per explicit command measurable.
    ///
    ///   ping <n>        → pong <n>, from this (the UI) thread, at once: the
    ///                     supervisor's liveness check (crates/ditto-supervisor)
    ///   recall          bring the character back when it is covered or hidden
    ///   workspace <id>  the same capability call as a click on the panel
    ///   command <id>    run a Shell-owned command locally (development and
    ///                     verification; the product path is `shell.command`)
    ///   focus           → one JSON line: the accessible name and role of the
    ///                     control with keyboard focus in the centers, and the
    ///                     names of the groups around it. Read-only; a keyboard
    ///                     verification run uses it to know where Tab went
    ///   tasks           → one JSON line: whether a tasks panel is mounted and
    ///                     the open tasks it holds to show. Read-only
    SocketServer {
        active: true
        path: (Quickshell.env("DITTO_RUNTIME_DIR")
            || ((Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/ditto")) + "/shell.sock"
        handler: Socket {
            id: connection
            parser: SplitParser {
                splitMarker: "\n"
                onRead: line => {
                    const command = line.trim().split(" ");
                    if (command[0] === "ping" && command.length === 2) {
                        connection.write("pong " + command[1] + "\n");
                        connection.flush();
                    } else if (command[0] === "recall") {
                        root.avatarRecalled = true;
                        if (avatarLoader.item) {
                            avatarLoader.item.aboveWindows = true;
                        }
                        console.log("ditto-shell avatar recalled");
                    } else if (command[0] === "workspace" && command.length === 2) {
                        client.activateWorkspace(command[1]);
                    } else if (command[0] === "command" && command.length === 2) {
                        root.runCommand(command[1], {});
                    } else if (command[0] === "focus") {
                        connection.write(JSON.stringify(root.focusReport()) + "\n");
                        connection.flush();
                    } else if (command[0] === "tasks") {
                        connection.write(JSON.stringify(root.tasksReport()) + "\n");
                        connection.flush();
                    } else {
                        console.log("ditto-shell ignored control line");
                    }
                }
            }
        }
    }

    Component.onCompleted: console.log("ditto-shell started")
}
