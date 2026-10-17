pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Effects

/// The soft-jelly material for the Shell's own surfaces: a translucent fill,
/// a thin outline with a bright inner edge, a faint top sheen and a wide soft
/// shadow. Everything comes from the tokens, so reduced transparency and the
/// low-power style reach every surface at once.
///
/// The shadow has three paths, and the surface, its content, its focus and
/// its hit region are the same on all of them (the material takes no input):
/// - `effect`: a MultiEffect blur of this item's own shadow shape. It works
///   only on that shape; it never samples what is behind the surface, so it
///   is not a compositor backdrop blur.
/// - `layered`: a few stacked translucent rectangles, no shader. Used with
///   reduced transparency and on the software renderer, where shader effects
///   do not draw.
/// - `none`: the low-power style (no shadow at all), or `raised: false`.
/// The effect is created only on the `effect` path; on the others no
/// MultiEffect exists.
///
/// All of this is the light recipe's (`tokens.lightRecipe`). Any other theme
/// keeps the material as it was before (`legacy`): the fill and a plain
/// offset rectangle for a shadow, pixel for pixel.
Item {
    id: material

    required property var tokens
    property real radius: tokens.radiusMedium
    property color color: tokens.surface
    property bool raised: true
    /// Shader effects need a hardware scene graph. Unknown before the item is
    /// in a window; then the non-shader path is used until it is known.
    property bool shaderCapable: GraphicsInfo.api !== GraphicsInfo.Software
        && GraphicsInfo.api !== GraphicsInfo.Unknown

    /// The soft material is the light recipe's; other themes keep the old one.
    readonly property bool soft: tokens.lightRecipe === true
    readonly property string shadowPath: !raised || !tokens.shadowEnabled ? "none"
        : !soft ? "legacy"
        : (tokens.effectsEnabled && shaderCapable ? "effect" : "layered")
    /// Shadow reach below the surface, in pixels.
    readonly property real shadowOffset: Math.round(Math.max(2, tokens.shadowRadius * 0.4))

    /// Legacy shadow: the second rectangle of the material before #65.
    Rectangle {
        objectName: "materialLegacyShadow"
        visible: material.shadowPath === "legacy"
        anchors.fill: parent
        anchors.topMargin: 3
        anchors.leftMargin: 1
        anchors.rightMargin: -1
        anchors.bottomMargin: -4
        radius: material.radius + 2
        color: material.tokens.shadowColor
        opacity: 0.55
    }

    Loader {
        id: effectShadow
        objectName: "materialEffectShadow"
        anchors.fill: parent
        active: material.shadowPath === "effect"
        sourceComponent: Item {
            Rectangle {
                id: shape
                anchors.fill: parent
                anchors.leftMargin: material.shadowOffset
                anchors.rightMargin: material.shadowOffset
                anchors.topMargin: material.shadowOffset * 2
                anchors.bottomMargin: -material.shadowOffset
                radius: material.radius
                color: material.tokens.shadowColor
                visible: false
            }

            MultiEffect {
                objectName: "materialShadowEffect"
                source: shape
                anchors.fill: shape
                autoPaddingEnabled: true
                blurEnabled: true
                blur: 1.0
                blurMax: Math.max(1, Math.round(material.tokens.shadowRadius * 2))
            }
        }
    }

    Item {
        objectName: "materialLayeredShadow"
        anchors.fill: parent
        visible: material.shadowPath === "layered"

        Repeater {
            model: [0.34, 0.22, 0.12, 0.06]

            Rectangle {
                required property real modelData
                required property int index
                readonly property real spread: (index + 1) * Math.max(1, material.shadowOffset / 2)
                anchors.fill: parent
                anchors.leftMargin: material.shadowOffset - spread
                anchors.rightMargin: material.shadowOffset - spread
                anchors.topMargin: material.shadowOffset * 2 - spread
                anchors.bottomMargin: -material.shadowOffset - spread
                radius: material.radius + spread
                color: material.tokens.shadowColor
                opacity: modelData
            }
        }
    }

    Rectangle {
        objectName: "materialFill"
        anchors.fill: parent
        radius: material.radius
        color: material.color
        border.color: material.tokens.border
        border.width: 1
        opacity: material.tokens.surfaceOpacity
    }

    /// The faint top sheen: a plain gradient, no shader. Not drawn with
    /// reduced transparency, where the surface stays one opaque colour.
    Rectangle {
        visible: material.soft && !material.tokens.reducedTransparency
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: 1
        height: Math.min(48, parent.height * 0.4)
        radius: Math.max(0, material.radius - 1)
        gradient: Gradient {
            GradientStop { position: 0.0; color: Qt.rgba(1, 1, 1, material.tokens.lightRecipe ? 0.34 : 0.04) }
            GradientStop { position: 1.0; color: "transparent" }
        }
    }

    /// The bright inner edge.
    Rectangle {
        visible: material.soft
        anchors.fill: parent
        anchors.margins: 1
        radius: Math.max(0, material.radius - 1)
        color: "transparent"
        border.color: material.tokens.highlight
        border.width: 1
    }
}
