import QtQuick

/// The character. Every animation here is local: it keeps running when the
/// desktop service is gone, because it never waits on a request. The task
/// state (PRD AVA-04: idle, thinking, executing, awaiting, done, failed,
/// offline; plus starting) comes from Core's turn state through the Shell,
/// is always also written as text beside the character, and each state has a
/// shape cue that does not rely on colour. Loops run only while their state
/// holds; reduced motion keeps only the static cues.
Item {
    id: avatar

    required property var tokens
    /// The Shell's translator (core/Tr.qml); null leaves the source text.
    property var tr: null
    /// The Profile's `avatar.animations`; reduced motion stops them as well.
    property bool animations: true
    readonly property bool animate: animations && !tokens.reducedMotion
    /// Set from the conversation's task state; "idle" when there is none.
    property string avatarState: "idle"
    readonly property string stateText: avatarState === "idle"
        ? (tr ? tr.t(qsTr("待命中")) : qsTr("待命中"))
        : avatarState
    property bool gazeActive: false
    property real gazeX: 0
    property real gazeY: 0

    signal pressed()

    implicitWidth: 220
    implicitHeight: 220

    Item {
        id: body
        anchors.fill: parent

        // Failed: a slight droop; offline: dimmed. Static, so reduced motion
        // keeps them.
        opacity: avatar.avatarState === "offline" ? 0.55 : 1
        transform: [
            Scale {
                id: breath
                origin.x: body.width / 2
                origin.y: body.height
                xScale: 1
                yScale: avatar.avatarState === "failed" ? 0.95 : 1
            },
            Rotation {
                id: sway
                origin.x: body.width / 2
                origin.y: body.height
                angle: 0
            },
            Translate {
                id: bob
                y: 0
            }
        ]

        Rectangle {
            id: shadow
            anchors.horizontalCenter: parent.horizontalCenter
            y: parent.height * 0.88
            width: parent.width * 0.62
            height: parent.height * 0.08
            radius: height / 2
            color: "#33000000"
            opacity: 0.6
        }

        Image {
            id: bodyLayer
            anchors.fill: parent
            source: Qt.resolvedUrl("layers/body.png")
            fillMode: Image.PreserveAspectFit
            smooth: true
            mipmap: true
        }

        Item {
            id: face
            anchors.fill: parent

            Repeater {
                model: [-1, 1]

                Item {
                    required property int modelData
                    x: face.width / 2 + modelData * face.width * 0.12 - width / 2
                    y: face.height * 0.46
                    width: face.width * 0.075
                    height: face.height * 0.105

                    Rectangle {
                        id: eye
                        anchors.fill: parent
                        radius: width / 2
                        color: "#2b2440"
                        scale: 1
                        transform: Scale {
                            id: lid
                            origin.x: eye.width / 2
                            origin.y: eye.height / 2
                            // Offline: half-closed eyes.
                            yScale: blink.closed * (avatar.avatarState === "offline" ? 0.45 : 1)
                        }

                        Rectangle {
                            width: parent.width * 0.34
                            height: width
                            radius: width / 2
                            color: "#f4f1ff"
                            x: parent.width * 0.2 + avatar.gazeX * parent.width * 0.18
                            y: parent.height * 0.22 + avatar.gazeY * parent.height * 0.18
                            Behavior on x { NumberAnimation { duration: avatar.tokens.durationFast } }
                            Behavior on y { NumberAnimation { duration: avatar.tokens.durationFast } }
                        }
                    }
                }
            }

            Rectangle {
                id: mouth
                anchors.horizontalCenter: parent.horizontalCenter
                y: parent.height * (avatar.avatarState === "done" ? 0.59 : 0.6)
                // Done: a wide smile; failed: a small flat mouth.
                width: parent.width * (avatar.avatarState === "done" ? 0.14 : avatar.avatarState === "failed" ? 0.06 : 0.09)
                height: parent.height * (avatar.avatarState === "done" ? 0.04 : 0.022)
                radius: height / 2
                color: "#2b2440"
                opacity: 0.85
            }
        }

        // Awaiting: a question mark the person can see at a glance.
        Rectangle {
            visible: avatar.avatarState === "awaiting"
            x: parent.width * 0.7
            y: parent.height * 0.12
            width: parent.width * 0.18
            height: width
            radius: width / 2
            color: avatar.tokens.warning
            Text {
                anchors.centerIn: parent
                text: "?"
                color: avatar.tokens.statusForeground
                font.pixelSize: parent.height * 0.7
                font.bold: true
            }
        }
    }

    /// Thinking: a slow sway. Only while thinking.
    SequentialAnimation {
        running: avatar.visible && avatar.animate && avatar.avatarState === "thinking"
        loops: Animation.Infinite
        onRunningChanged: if (!running) sway.angle = 0
        NumberAnimation { target: sway; property: "angle"; to: 3; duration: 700; easing.type: Easing.InOutSine }
        NumberAnimation { target: sway; property: "angle"; to: -3; duration: 1400; easing.type: Easing.InOutSine }
        NumberAnimation { target: sway; property: "angle"; to: 0; duration: 700; easing.type: Easing.InOutSine }
    }

    /// Executing: a quick working bob. Only while executing.
    SequentialAnimation {
        running: avatar.visible && avatar.animate && avatar.avatarState === "executing"
        loops: Animation.Infinite
        onRunningChanged: if (!running) bob.y = 0
        NumberAnimation { target: bob; property: "y"; to: -6; duration: 220; easing.type: Easing.OutQuad }
        NumberAnimation { target: bob; property: "y"; to: 0; duration: 260; easing.type: Easing.InQuad }
    }

    /// Done: one bounce, then still (no loop: the task is over).
    SequentialAnimation {
        id: doneBounce
        NumberAnimation { target: bob; property: "y"; to: -14; duration: 180; easing.type: Easing.OutQuad }
        NumberAnimation { target: bob; property: "y"; to: 0; duration: 320; easing.type: Easing.OutBounce }
    }
    onAvatarStateChanged: if (avatarState === "done" && animate) doneBounce.restart()

    /// Breathing: a slow scale that never stops and never asks anything of Core.
    SequentialAnimation {
        running: avatar.visible && avatar.animate
        loops: Animation.Infinite

        ParallelAnimation {
            NumberAnimation { target: breath; property: "yScale"; to: 1.035; duration: avatar.tokens.durationSlow; easing.type: Easing.InOutSine }
            NumberAnimation { target: breath; property: "xScale"; to: 0.985; duration: avatar.tokens.durationSlow; easing.type: Easing.InOutSine }
        }
        ParallelAnimation {
            NumberAnimation { target: breath; property: "yScale"; to: 1.0; duration: avatar.tokens.durationSlow; easing.type: Easing.InOutSine }
            NumberAnimation { target: breath; property: "xScale"; to: 1.0; duration: avatar.tokens.durationSlow; easing.type: Easing.InOutSine }
        }
    }

    QtObject {
        id: blink
        property real closed: 1
    }

    /// Blinks are deliberately uneven: a fixed interval reads as a machine.
    Timer {
        id: blinkTimer
        running: avatar.visible && avatar.animate
        repeat: true
        interval: 2600 + Math.random() * 3200
        onTriggered: {
            blinkAnimation.restart();
            interval = 2600 + Math.random() * 3200;
        }
    }

    SequentialAnimation {
        id: blinkAnimation
        NumberAnimation { target: blink; property: "closed"; to: 0.08; duration: 70 }
        NumberAnimation { target: blink; property: "closed"; to: 1.0; duration: 110 }
    }

    SequentialAnimation {
        id: pressAnimation
        NumberAnimation { target: breath; property: "yScale"; to: 0.9; duration: avatar.tokens.durationFast; easing.type: Easing.OutQuad }
        NumberAnimation { target: breath; property: "yScale"; to: 1.0; duration: avatar.tokens.durationMedium; easing.type: Easing.OutBack }
    }

    MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        onEntered: avatar.gazeActive = true
        onExited: {
            avatar.gazeActive = false;
            avatar.gazeX = 0;
            avatar.gazeY = 0;
        }
        /// Gaze follows the pointer only inside the avatar's own area: the
        /// desktop gives no global pointer position, and pretending otherwise
        /// would mean polling.
        onPositionChanged: mouse => {
            avatar.gazeX = Math.max(-1, Math.min(1, (mouse.x - width / 2) / (width / 2)));
            avatar.gazeY = Math.max(-1, Math.min(1, (mouse.y - height / 2) / (height / 2)));
        }
        onClicked: {
            if (avatar.animate) {
                pressAnimation.restart();
            }
            console.log("ditto-avatar-hit")
            avatar.pressed();
        }
    }
}
