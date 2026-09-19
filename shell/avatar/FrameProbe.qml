import QtQuick
import Quickshell

/// Frame interval sampling for the frame-time check. Millisecond resolution is
/// the limit of the QML clock, so a run on the reference machine cross-checks
/// this against the compositor's presentation timestamps before any frame-time
/// claim is made.
Item {
    id: probe

    property bool active: Quickshell.env("DITTO_FRAME_PROBE") === "1"
    property double previous: 0
    property int frames: 0

    visible: false

    Connections {
        target: probe.active ? probe.Window.window : null
        ignoreUnknownSignals: true

        function onFrameSwapped() {
            const now = Date.now();
            if (probe.previous > 0) {
                probe.frames += 1;
                console.log("ditto-frame " + now + " " + (now - probe.previous));
            }
            probe.previous = now;
        }
    }
}
