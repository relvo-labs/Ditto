pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Shapes
import QtQuick.Window

/// Owner-selected D1 reuses the existing body asset. See SOURCES.md.
Item {
    id: symbol
    required property var tokens
    property string variant: "neutral"
    readonly property bool isDitto: variant === "ditto"
    property real activityOpacity: 1
    implicitWidth: 32
    implicitHeight: 32

    Rectangle {
        visible: !symbol.isDitto
        anchors.centerIn: parent
        width: 28
        height: symbol.variant === "portrait" ? 30 : 23
        radius: symbol.variant === "portrait" ? 9 : 6
        color: symbol.tokens.surfaceStrong
        border.color: symbol.tokens.foregroundMuted
        border.width: 1
        Row {
            anchors.centerIn: parent
            spacing: symbol.variant === "portrait" ? 7 : 4
            Repeater {
                model: symbol.variant === "portrait" ? 2 : 3
                Rectangle {
                    width: 3
                    height: symbol.variant === "portrait" ? 6 : 3
                    radius: 1.5
                    color: symbol.tokens.foreground
                }
            }
        }
    }

    Rectangle {
        visible: symbol.isDitto
        anchors.fill: parent
        radius: width / 2
        gradient: Gradient {
            GradientStop { position: 0; color: "#ccb5ef" }
            GradientStop { position: 1; color: "#b49bdc" }
        }
        Image {
            objectName: "dittoBodyImage"
            visible: symbol.variant === "ditto"
            anchors.fill: parent
            source: visible ? Qt.resolvedUrl("../avatar/layers/body.png") : ""
            sourceSize: Qt.size(Math.ceil(width * 3 * Screen.devicePixelRatio), Math.ceil(height * 3 * Screen.devicePixelRatio))
            opacity: 0.84 * symbol.activityOpacity
            smooth: true
            mipmap: true
            fillMode: Image.PreserveAspectFit
        }
        Rectangle {
            objectName: "dittoEdgeRing"
            anchors.fill: parent
            radius: width / 2
            color: "transparent"
            border.color: symbol.tokens.foregroundMuted
            border.width: 2.5
        }
        Repeater {
            model: [-1, 1]
            Rectangle {
                required property int modelData
                x: symbol.width / 2 + modelData * symbol.width * 0.12 - width / 2
                y: symbol.height * 0.46
                width: symbol.width * 0.065
                height: symbol.height * 0.095
                radius: width / 2
                color: "#39285a"
            }
        }
        Shape {
            anchors.fill: parent
            ShapePath {
                scale: Qt.size(symbol.width / 100, symbol.height / 100)
                strokeColor: "#39285a"
                strokeWidth: 2.2
                capStyle: ShapePath.RoundCap
                fillColor: "transparent"
                PathSvg { path: "M 46 60 Q 50 65 54 60" }
            }
        }
    }
}
