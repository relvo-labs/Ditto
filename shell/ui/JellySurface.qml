pragma ComponentBehavior: Bound
import QtQuick

/// The #116 candidates' soft-jelly face: a rounded fill with a bright inner
/// edge, a faint top sheen (a jelly's convex highlight), optionally an
/// iridescent rim along the top (J3's bubble film) and a soft lavender shadow
/// below. Plain rectangles and gradients, no shader; reduced transparency and
/// the low-power style drop the gloss (and, low power, the shadow) through
/// `tokens.uiGloss` / `tokens.uiShadows`. It takes no input.
Item {
    id: surface

    required property var tokens
    property real radius: tokens.uiRadiusCard
    property color fill: tokens.uiCard
    /// With gloss, the fill runs from this colour at the top to `fill`.
    property color fillTop: fill
    property color edge: tokens.uiCardBorder
    property int edgeWidth: 1
    /// Soft shadow below; `lift` scales its strength (0 hides it).
    property bool raised: true
    property real lift: 1
    property bool sheen: true
    property bool iris: false

    readonly property bool gloss: tokens.uiGloss === true

    Repeater {
        model: surface.raised && surface.lift > 0 && surface.tokens.uiShadows === true
            ? (surface.tokens.uiJ2 ? [0.60, 0.26] : [0.46, 0.22, 0.09]) : []

        Rectangle {
            required property real modelData
            required property int index
            readonly property real spread: (index + 1) * (surface.tokens.uiJ2 ? 1.5 : 2.5)
            anchors.fill: parent
            anchors.leftMargin: 2 - spread
            anchors.rightMargin: 2 - spread
            anchors.topMargin: (surface.tokens.uiJ2 ? 3 : 4) - spread
            anchors.bottomMargin: -(surface.tokens.uiJ2 ? 3 : 4) - spread
            radius: surface.radius + spread
            color: surface.tokens.uiShadow
            opacity: modelData * Math.min(1, surface.lift)
        }
    }

    Rectangle {
        objectName: "jellyFill"
        anchors.fill: parent
        radius: surface.radius
        color: surface.fill
        border.color: surface.edge
        border.width: surface.edgeWidth
    }

    /// Convex body: lighter at the top, only with gloss.
    Rectangle {
        visible: surface.gloss && !Qt.colorEqual(surface.fillTop, surface.fill)
        anchors.fill: parent
        anchors.margins: surface.edgeWidth
        radius: Math.max(0, surface.radius - surface.edgeWidth)
        gradient: Gradient {
            GradientStop { position: 0.0; color: surface.fillTop }
            GradientStop { position: 1.0; color: surface.fill }
        }
    }

    /// The sheen: a short white fade from the top edge.
    Rectangle {
        objectName: "jellySheen"
        visible: surface.gloss && surface.sheen
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: surface.edgeWidth
        height: Math.max(0, Math.min(22, parent.height * 0.45))
        radius: Math.max(0, surface.radius - surface.edgeWidth)
        gradient: Gradient {
            GradientStop { position: 0.0; color: Qt.rgba(1, 1, 1, surface.tokens.uiJ2 ? 0.55 : 0.42) }
            GradientStop { position: 1.0; color: Qt.rgba(1, 1, 1, 0) }
        }
    }

    /// Bright inner edge.
    Rectangle {
        visible: surface.gloss && surface.sheen
        anchors.fill: parent
        anchors.margins: surface.edgeWidth
        radius: Math.max(0, surface.radius - surface.edgeWidth)
        color: "transparent"
        border.color: surface.tokens.uiCardHighlight
        border.width: 1
    }

    /// Iridescent film along the top edge, inside the corner curve.
    Rectangle {
        objectName: "jellyIris"
        visible: surface.gloss && surface.iris
        x: Math.min(surface.width / 2, surface.radius * 0.8)
        width: Math.max(0, surface.width - x * 2)
        y: 1
        height: 2
        radius: 1
        opacity: 0.95
        gradient: Gradient {
            orientation: Gradient.Horizontal
            GradientStop { position: 0.0; color: surface.tokens.uiIris[0] }
            GradientStop { position: 0.5; color: surface.tokens.uiIris[1] }
            GradientStop { position: 1.0; color: surface.tokens.uiIris[2] }
        }
    }
}
