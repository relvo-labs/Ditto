import QtQuick
import Quickshell
import Quickshell.Wayland

/// Functional probe for the neutral window protocol (matrix rows C-02 and
/// C-03). It enumerates what the compositor advertises through
/// foreign-toplevel, then asks for each state change and reads back what the
/// protocol reports, so "advertised" and "works" stay separate findings.
ShellRoot {
    id: root

    readonly property string target: Quickshell.env("DITTO_PROBE_APP_ID") || "ditto-probe"
    property var findings: ({})

    function toplevelFor(appId) {
        for (const toplevel of ToplevelManager.toplevels.values) {
            if (toplevel.appId === appId) {
                return toplevel;
            }
        }
        return null;
    }

    Timer {
        interval: 400
        repeat: true
        running: true
        property int attempts: 0

        onTriggered: {
            attempts += 1;
            const toplevel = root.toplevelFor(root.target);
            if (!toplevel) {
                if (attempts > 15) {
                    console.log("PROBE_JSON " + JSON.stringify({
                        enumeration: { supported: false, reason: "no toplevel was announced for the probe window" }
                    }));
                    Qt.exit(1);
                }
                return;
            }
            running = false;
            const enumeration = {
                supported: true,
                count: ToplevelManager.toplevels.values.length,
                app_id: toplevel.appId,
                title_present: toplevel.title.length > 0,
                activated_field_present: toplevel.activated !== undefined
            };
            toplevel.activate();
            const requests = [];
            const steps = [
                { name: "activate", apply: () => toplevel.activate(), read: () => toplevel.activated },
                { name: "maximize", apply: () => toplevel.maximized = true, read: () => toplevel.maximized },
                { name: "unmaximize", apply: () => toplevel.maximized = false, read: () => !toplevel.maximized },
                { name: "fullscreen", apply: () => toplevel.fullscreen = true, read: () => toplevel.fullscreen },
                { name: "unfullscreen", apply: () => toplevel.fullscreen = false, read: () => !toplevel.fullscreen },
                { name: "minimize", apply: () => toplevel.minimized = true, read: () => toplevel.minimized }
            ];
            let index = 0;
            const runner = Qt.createQmlObject('import QtQuick; Timer { interval: 600; repeat: true; running: true }', root);
            runner.triggered.connect(function () {
                if (index > 0) {
                    const previous = steps[index - 1];
                    requests.push({ request: previous.name, observed: previous.read() === true });
                }
                if (index >= steps.length) {
                    runner.running = false;
                    console.log("PROBE_JSON " + JSON.stringify({ enumeration: enumeration, control: requests }));
                    Qt.exit(0);
                    return;
                }
                steps[index].apply();
                index += 1;
            });
        }
    }
}
