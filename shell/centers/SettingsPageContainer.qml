import QtQuick

/// The window owns page instances; ProviderHost holds compiled types only.
Item {
    id: container
    required property var client
    required property var tokens
    property var aiSettings: null
    property string pageId: ""
    property var registration: null
    property Component fallbackComponent: null
    property bool active: true
    property Item embedded: null
    property bool failed: false
    readonly property bool usingFallback: !embedded
    readonly property Item item: embedded || fallback.item
    readonly property Flickable flickable: embedded
        ? (embedded.flickable !== undefined ? embedded.flickable as Flickable : null)
        : fallback.item as Flickable

    function reload() {
        if (embedded) {
            embedded.destroy();
            embedded = null;
        }
        failed = false;
        if (!active || !registration) return;
        const component = registration.component;
        if (!component || component.status !== Component.Ready) {
            failed = true;
            return;
        }
        const object = component.createObject(container, {
            client: client, tokens: tokens, config: registration.config || {},
            pageId: pageId, entryId: registration.entry_id
        });
        if (!(object instanceof Item)) {
            if (object) object.destroy();
            console.log("ditto-shell settings page " + pageId + " failed to instantiate: " + component.errorString());
            failed = true;
            return;
        }
        // Optional inputs must not become unknown-property creation errors
        // for pages which do not declare them.
        if ("aiSettings" in object)
            object.aiSettings = Qt.binding(() => container.aiSettings);
        embedded = object;
        object.anchors.fill = container;
    }
    onRegistrationChanged: Qt.callLater(reload)
    onPageIdChanged: Qt.callLater(reload)
    onActiveChanged: Qt.callLater(reload)
    Component.onCompleted: Qt.callLater(reload)

    Loader {
        id: fallback
        anchors.fill: parent
        active: container.active && !container.embedded && (!container.registration || container.failed)
        sourceComponent: container.fallbackComponent
    }
    Text {
        objectName: "settingsPageError"
        visible: container.active && !!container.registration && !container.embedded && !container.fallbackComponent
        anchors.fill: parent
        anchors.margins: container.tokens ? container.tokens.space : 12
        wrapMode: Text.WordWrap
        text: container.client ? container.client.t(qsTr("這個頁面無法載入。請在插件中心停用它，或稍後再試。")) : ""
        color: container.tokens ? container.tokens.appWarning : "#ffcf8b"
        font.pixelSize: container.tokens ? container.tokens.appFontBody : 14
        Accessible.role: Accessible.AlertMessage
        Accessible.name: text
    }
}
