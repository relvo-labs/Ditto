import QtQuick

/// The desktop canvas: what is behind every window and Shell surface.
///
/// Without a wallpaper it is the token canvas, a soft gradient in the light
/// recipe and the flat background otherwise (plain Rectangle gradients, no
/// shader). `wallpaperSource` is the hookup for a clean wallpaper: the image
/// is shown only once it has loaded; while it loads, or if it fails, the
/// canvas stays. Nothing here picks a wallpaper. Which image, its rights and
/// its fit on several outputs are not decided yet (#51), and the path has no
/// Profile field yet (component-sheet.md, handoff to #45 and Core).
Item {
    id: backdrop

    required property var tokens
    /// A local image URL, or empty for none.
    property url wallpaperSource: ""
    /// `Image.PreserveAspectCrop` (fill, cropping the overflow) unless the
    /// asset decision says otherwise.
    property int wallpaperFillMode: Image.PreserveAspectCrop
    readonly property bool wallpaperShown: wallpaper.status === Image.Ready

    Rectangle {
        objectName: "backdropCanvas"
        anchors.fill: parent
        gradient: Gradient {
            GradientStop { position: 0.0; color: backdrop.tokens.canvasTop }
            GradientStop { position: 1.0; color: backdrop.tokens.canvasBottom }
        }
    }

    /// Lighter towards the right, where the reference leaves open space.
    Rectangle {
        anchors.fill: parent
        visible: backdrop.tokens.canvasGlow.a > 0
        gradient: Gradient {
            orientation: Gradient.Horizontal
            GradientStop { position: 0.0; color: "transparent" }
            GradientStop { position: 1.0; color: backdrop.tokens.canvasGlow }
        }
    }

    Image {
        id: wallpaper
        objectName: "backdropWallpaper"
        anchors.fill: parent
        source: backdrop.wallpaperSource
        fillMode: backdrop.wallpaperFillMode
        asynchronous: true
        cache: false
        sourceSize.width: Math.max(1, backdrop.width)
        sourceSize.height: Math.max(1, backdrop.height)
        visible: backdrop.wallpaperShown
    }
}
