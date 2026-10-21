import QtQuick
import Quickshell
import "jelly"

ShellRoot {
    id: root
    property var heldPage: null
    property var component: null
    Tokens { id: tokens; readsSystemPreference: false }
    QtObject {
        id: client
        signal capabilitiesReloaded()
        signal changeUpdated(var change)
        function t(source) { return source; }
        function key(source, args) { return source; }
        function capability(name, args, done, fail) { done({changes: []}); }
    }
    Item { id: visualParent; width: 800; height: 600 }
    Component.onCompleted: {
        component = Qt.createComponent(Qt.resolvedUrl("package/qml/HistoryPage.qml"));
        if (component.status !== Component.Ready) {
            console.log("REAL_PAGE_FAILED " + component.errorString());
            return;
        }
        heldPage = component.createObject(visualParent, {client: client, tokens: tokens,
            config: {}, pageId: "history", entryId: "real-history"});
        if (heldPage && heldPage.pageId === "history" && heldPage.flickable === heldPage && heldPage.changes.length === 0) {
            console.log("REAL_PAGE_READY root:/sdk/Ditto/Ui packaged history");
        } else {
            console.log("REAL_PAGE_FAILED " + component.errorString());
        }
    }
    Timer { interval: 100; running: true; onTriggered: Qt.quit() }
}
