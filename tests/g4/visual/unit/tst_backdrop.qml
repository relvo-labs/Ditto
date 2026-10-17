import QtQuick
import QtTest
import "../../../../shell/jelly" as Jelly

// shell/jelly/Backdrop.qml: the canvas, and the wallpaper shown only once it
// has loaded. The fixture is a flat test image written for this test, not a
// wallpaper candidate.
TestCase {
    id: testCase
    name: "SoftJellyBackdrop"
    width: 320
    height: 200
    visible: true
    when: windowShown

    Component { id: tokensFactory; Jelly.Tokens {} }
    Component { id: backdropFactory; Jelly.Backdrop { width: 320; height: 200 } }

    function make(theme, source) {
        const tokens = createTemporaryObject(tokensFactory, testCase, { appearance: { theme: theme, tokens: {}, locale: "zh-TW" } });
        return createTemporaryObject(backdropFactory, testCase, { tokens: tokens, wallpaperSource: source });
    }

    function test_canvas_without_wallpaper() {
        const view = make("soft-jelly-light", "");
        verify(!view.wallpaperShown);
        verify(!findChild(view, "backdropWallpaper").visible);
        verify(findChild(view, "backdropCanvas").visible);
        const image = grabImage(view);
        // Lighter on the right than on the left.
        const right = image.pixel(315, 100), left = image.pixel(3, 100);
        verify(right.r + right.g + right.b > left.r + left.g + left.b);
    }

    function test_dark_canvas_stays_flat() {
        const view = make("soft-jelly", "");
        const image = grabImage(view);
        compare(String(image.pixel(315, 3)), String(image.pixel(3, 196)));
        compare(String(image.pixel(3, 196)), "#12121a");
    }

    function test_wallpaper_shown_once_loaded() {
        const view = make("soft-jelly-light", Qt.resolvedUrl("../fixtures/plain-wallpaper.svg"));
        tryCompare(view, "wallpaperShown", true, 3000);
        verify(findChild(view, "backdropWallpaper").visible);
        const pixel = grabImage(view).pixel(160, 100);
        compare(String(pixel), "#336699");
    }

    function test_missing_wallpaper_keeps_the_canvas() {
        const view = make("soft-jelly-light", Qt.resolvedUrl("../fixtures/does-not-exist.png"));
        tryCompare(findChild(view, "backdropWallpaper"), "status", Image.Error, 3000);
        verify(!view.wallpaperShown);
        verify(!findChild(view, "backdropWallpaper").visible);
        verify(findChild(view, "backdropCanvas").visible);
    }
}
