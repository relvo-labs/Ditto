import QtQuick
import QtTest
import DittoStub
import "../../../../shell/jelly" as Jelly

// #72: every remaining caller, rendered with labelled fixture data. Layer
// shell and FloatingWindow are stubs; sources and colour bindings are real.
TestCase {
    id: testCase
    name: "CaptureAccentSurfaces"
    width: 1280; height: 800
    visible: true
    when: windowShown
    Jelly.Tokens { id: sceneTokens }
    Rectangle { id: scene; width: 1280; height: 800; color: sceneTokens.background }
    QtObject {
        id: client
        property bool online: true
        property string status: "Fixture: no Core connection"
        property var tr: ({ slotName: name => name, packageName: name => name, has: key => false })
        property string mode: "normal"
        property string tasksStatus: "available"
        property var tasks: ({ demo: true, tasks: [{ id: "fixture", text: "Fixture task", done: false }] })
        signal profileChanged(var payload)
        signal changeUpdated(var change)
        signal capabilitiesReloaded()
        function t(text) { return text; }
        function key(text, args) { return text; }
        function errorText(error) { return "Fixture: no Core connection"; }
        function diagnosticText(error) { return ""; }
        function watchTasks() {}
        function unwatchTasks() {}
        function capability(method, args, ok, fail) {
            if (fail) fail({ name: "unavailable" });
        }
    }
    function test_capture() {
        failOnWarning(/./);
        StubDesktop.layer = scene;
        for (const theme of ["no-theme", "soft-jelly", "soft-jelly-light"]) {
            sceneTokens.appearance = theme === "no-theme" ? { tokens: {} } : { theme: theme, tokens: {} };
            for (const name of ["LauncherGrid", "LauncherSearch", "TasksPanel", "Centers"]) {
                const file = name === "Centers" ? "../../../../shell/centers/Centers.qml" : "../.staged/providers/" + name + ".qml";
                const component = Qt.createComponent(Qt.resolvedUrl(file));
                verify(component.status === Component.Ready, component.errorString());
                const object = component.createObject(testCase, { tokens: sceneTokens, client: client });
                verify(object !== null);
                if (name !== "Centers") object.shown = true;
                if (name === "LauncherGrid") {
                    object.apps = [{ app_id: "fixture", name: "Fixture app", categories: ["Utility"] }];
                    object.isOpen = true;
                } else if (name === "LauncherSearch") {
                    object.isOpen = true;
                    object.results = [{ app_id: "fixture", name: "Fixture result", description: "Fixture description" }];
                }
                waitForRendering(scene);
                grabImage(scene).save(Qt.resolvedUrl("../.staged/out/accent-" + name + "-" + theme + ".png").toString().replace("file://", ""));
                if (object.release) object.release();
                object.destroy();
                wait(0);
            }
        }
    }
}
