pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Shapes

/// D1 (ditto) reuses the existing body asset; D2 (ditto-vector) is QML only.
/// Both are opt-in candidates, pending owner choice. See SOURCES.md.
Item {
    id: symbol
    required property var tokens
    property string variant: "neutral"
    readonly property bool isDitto: variant === "ditto" || variant === "ditto-vector"
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
            GradientStop { position: 0; color: "#f6f0ff" }
            GradientStop { position: 1; color: "#ddd1f8" }
        }
        Image {
            objectName: "dittoBodyImage"
            visible: symbol.variant === "ditto"
            anchors.fill: parent
            source: visible ? Qt.resolvedUrl("../avatar/layers/body.png") : ""
            sourceSize: Qt.size(Math.ceil(width * 2), Math.ceil(height * 2))
            smooth: true
            mipmap: true
            fillMode: Image.PreserveAspectFit
        }
        Shape {
            visible: symbol.variant === "ditto-vector"
            anchors.fill: parent
            // Coordinates are local vector units; no new raster asset.
            ShapePath {
                scale: Qt.size(symbol.width / 100, symbol.height / 100)
                strokeWidth: 0.7
                strokeColor: "#af95d9"
                fillGradient: LinearGradient {
                    x1: 25; y1: 20; x2: 70; y2: 90
                    GradientStop { position: 0; color: "#ede1ff" }
                    GradientStop { position: 0.55; color: "#c5acee" }
                    GradientStop { position: 1; color: "#b89be5" }
                }
                PathSvg { path: "M 13 54 C 22 52 23 49 28 35 C 35 10 62 10 71 35 C 75 48 77 52 88 54 C 103 57 99 72 87 74 C 93 87 76 91 66 84 C 54 94 43 88 36 84 C 22 91 9 86 15 75 C 0 74 1 58 13 54 Z" }
            }
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
