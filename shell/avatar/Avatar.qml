import QtQuick

/// The character. Every animation here is local: it keeps running when the
/// desktop service is gone, because it never waits on a request. G0 has exactly
/// one state — idle — and the state is always readable as text as well, so the
/// states added later cannot forget to bring their wording with them.
Item {
    id: avatar

    required property var tokens
    /// G0 shows no task states: an animation must not suggest work that is not
    /// happening. The text label is bound to this same value.
    property string avatarState: "idle"
    readonly property string stateText: avatarState === "idle" ? "待命中" : avatarState
    property bool gazeActive: false
    property real gazeX: 0
    property real gazeY: 0

    signal pressed()

    implicitWidth: 220
    implicitHeight: 220

    Item {
        id: body
        anchors.fill: parent

        transform: [
            Scale {
                id: breath
                origin.x: body.width / 2
                origin.y: body.height
                xScale: 1
                yScale: 1
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
                            yScale: blink.closed
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
                y: parent.height * 0.6
                width: parent.width * 0.09
                height: parent.height * 0.022
                radius: height / 2
                color: "#2b2440"
                opacity: 0.85
            }
        }
    }

    /// Breathing: a slow scale that never stops and never asks anything of Core.
    SequentialAnimation {
        running: avatar.visible && !avatar.tokens.reducedMotion
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
        running: avatar.visible && !avatar.tokens.reducedMotion
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
            if (!avatar.tokens.reducedMotion) {
                pressAnimation.restart();
            }
            avatar.pressed();
        }
    }
}
