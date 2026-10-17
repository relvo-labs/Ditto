import QtQuick
import QtTest
import "../../../../shell/jelly" as Jelly

// shell/jelly/Material.qml on its three shadow paths. Offscreen runs the
// software renderer, where no shader draws; `shaderCapable` is forced to
// check which path each mode chooses, not how the effect looks.
TestCase {
    id: testCase
    name: "SoftJellyMaterial"
    width: 400
    height: 300
    visible: true
    when: windowShown

    /// A material with something on it that takes clicks and focus, so the
    /// content's behaviour can be compared across the paths.
    Component {
        id: sceneFactory
        Item {
            id: sceneRoot
            required property var appearance
            readonly property var tokens: sceneTokens
            property bool shaderCapable: false
            property alias material: material
            property alias button: button
            property int clicks: 0
            width: 400
            height: 300

            Jelly.Tokens {
                id: sceneTokens
                appearance: sceneRoot.appearance
            }

            Jelly.Material {
                id: material
                x: 100
                y: 80
                width: 200
                height: 120
                tokens: sceneRoot.tokens
                shaderCapable: sceneRoot.shaderCapable
            }

            Rectangle {
                id: button
                x: 140
                y: 120
                width: 120
                height: 40
                activeFocusOnTab: true
                color: "transparent"
                Keys.onReturnPressed: parent.clicks += 1

                MouseArea {
                    anchors.fill: parent
                    onClicked: button.parent.clicks += 1
                }
            }
        }
    }

    function scene(appearance, shaderCapable) {
        return createTemporaryObject(sceneFactory, testCase, { appearance: appearance, shaderCapable: shaderCapable });
    }

    function light(extra) {
        return Object.assign({ theme: "soft-jelly-light", tokens: {}, locale: "zh-TW" }, extra || {});
    }

    function effect(view) {
        return findChild(view.material, "materialShadowEffect");
    }

    function layered(view) {
        return findChild(view.material, "materialLayeredShadow");
    }

    function test_software_renderer_is_detected() {
        const view = scene(light(), true);
        // The offscreen run draws with the software scene graph.
        const tokens = view.tokens;
        const plain = Qt.createComponent("../../../../shell/jelly/Material.qml")
            .createObject(view, { tokens: tokens, width: 50, height: 50 });
        compare(plain.GraphicsInfo.api, GraphicsInfo.Software);
        compare(plain.shaderCapable, false);
        compare(plain.shadowPath, "layered");
        compare(findChild(plain, "materialShadowEffect"), null);
        // and the scene's material, forced, takes the effect path instead
        compare(view.material.shadowPath, "effect");
    }

    function test_normal_uses_the_effect_on_its_own_shape() {
        const view = scene(light(), true);
        compare(view.material.shadowPath, "effect");
        const fx = effect(view);
        verify(fx !== null);
        // The effect's source is the material's own shadow shape, not
        // anything behind the surface.
        verify(fx.source !== null);
        compare(fx.source.parent, fx.parent);
        verify(!layered(view).visible);
    }

    function test_low_power_creates_no_effect_and_no_shadow() {
        const view = scene(light({ low_power_style: true }), true);
        compare(view.material.shadowPath, "none");
        compare(effect(view), null);
        compare(findChild(view.material, "materialEffectShadow").status, Loader.Null);
        verify(!layered(view).visible);
    }

    function test_reduced_transparency_takes_the_non_shader_path() {
        const view = scene(light({ reduced_transparency: true }), true);
        compare(view.material.shadowPath, "layered");
        compare(effect(view), null);
        verify(layered(view).visible);
        compare(findChild(view.material, "materialFill").opacity, 1);
    }

    function test_dark_low_power_creates_no_effect() {
        const view = scene({ theme: "soft-jelly", tokens: {}, low_power_style: true, locale: "zh-TW" }, true);
        compare(effect(view), null);
    }

    function test_content_hit_and_focus_are_the_same_on_every_path() {
        const modes = [light(), light({ reduced_transparency: true }), light({ low_power_style: true })];
        for (const appearance of modes) {
            for (const capable of [true, false]) {
                const view = scene(appearance, capable);
                compare(view.material.width, 200);
                compare(view.material.height, 120);
                mouseClick(view, 200, 140);
                compare(view.clicks, 1, "click through the material's content");
                // The material takes no input itself: a click on it outside
                // the content reaches nothing.
                mouseClick(view, 110, 90);
                compare(view.clicks, 1);
                view.button.forceActiveFocus();
                keyClick(Qt.Key_Return);
                compare(view.clicks, 2, "keyboard on the content");
                view.destroy();
            }
        }
    }
}
