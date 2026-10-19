import QtQuick
import Quickshell
import Quickshell.Wayland

// Quickshell 0.3.1 metadata marks this creatable runtime type uncreatable.
// qmllint disable uncreatable-type
PanelWindow {
    // qmllint enable uncreatable-type
    id: surface
    required property var tokens
    required property var conversation
    required property var client
    property string corner: "bottom_right"
    property real entryScale: 1
    property bool shown: true
    property string entryStyle: "capsule"
    property string symbolVariant: "neutral"
    property int fabSize: 48
    property string expansionMode: "label"
    property alias labelExpanded: entry.labelExpanded
    property bool expanded: false
    property bool animations: true
    signal activated()
    signal collapseRequested()
    visible: shown
    anchors {
        top: corner.indexOf("top") === 0
        bottom: corner.indexOf("bottom") === 0
        left: corner.indexOf("left") > 0
        right: corner.indexOf("right") > 0
    }
    // Quickshell 0.3.1 omits the grouped margins type from qmllint metadata.
    // Covered by the same layer-shell stub geometry assertions as ChatPanel.
    // qmllint disable unqualified unresolved-type missing-property
    margins { top: 64; bottom: 32; left: 32; right: 32 }
    // qmllint enable unqualified unresolved-type missing-property
    implicitWidth: Math.min(Math.round(entry.implicitWidth * entryScale), screen ? screen.width - 64 : 300)
    implicitHeight: Math.round(entry.implicitHeight * entryScale)
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    aboveWindows: true
    WlrLayershell.namespace: "ditto-assistant"
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand
    // Define the region in output pixels, including the selected scale.
    mask: Region { item: inputShape; radius: surface.implicitHeight / 2 }
    Item { id: inputShape; width: surface.implicitWidth; height: surface.implicitHeight }
    onShownChanged: if (!shown) reshow.stop()
    onVisibleChanged: if (!visible && shown) reshow.restart()
    onScreenChanged: { entry.settleMotion(); if (shown) reshow.restart(); }
    onCornerChanged: entry.settleMotion()
    onEntryScaleChanged: entry.settleMotion()
    Timer {
        id: reshow
        interval: 100
        onTriggered: if (surface.shown && !surface.visible) surface.visible = Qt.binding(() => surface.shown)
    }
    AssistantEntry {
        id: entry
        width: surface.implicitWidth / surface.entryScale
        height: surface.implicitHeight / surface.entryScale
        scale: surface.entryScale
        transformOrigin: Item.TopLeft
        tokens: surface.tokens
        conversation: surface.conversation
        client: surface.client
        entryStyle: surface.entryStyle
        symbolVariant: surface.symbolVariant
        fabSize: surface.fabSize
        expansionMode: surface.expansionMode
        expanded: surface.expanded
        animations: surface.animations
        onActivated: surface.activated()
        onCollapseRequested: surface.collapseRequested()
    }
}
