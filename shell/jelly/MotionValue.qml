import QtQuick

/// A single local interpolation. Retarget from the rendered value, never queue
/// completions. Disabling (including while running) settles synchronously.
QtObject {
    id: motion
    property real value: 1
    property real targetValue: 1
    property bool active: true
    property int duration: 120
    property int easing: Easing.OutCubic
    readonly property bool running: animation.running
    property bool ready: false

    function settle() {
        animation.stop();
        value = targetValue;
    }
    function retarget() {
        if (!ready) return;
        animation.stop();
        if (!active || duration <= 0 || value === targetValue) {
            value = targetValue;
            return;
        }
        animation.from = value;
        animation.to = targetValue;
        animation.start();
    }
    onTargetValueChanged: retarget()
    onActiveChanged: retarget()
    onDurationChanged: retarget()
    Component.onCompleted: { ready = true; retarget(); }
    property NumberAnimation animation: NumberAnimation {
        target: motion
        property: "value"
        duration: motion.duration
        easing.type: motion.easing
    }
}
