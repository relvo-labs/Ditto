import QtQuick
import Quickshell
import Quickshell.Wayland

/// Where the members of the `ui.status_item` area are shown (protocol 0.2
/// §9.1). Unlike a slot, the area holds any number of entries; each one is a
/// unit of its own in the ProviderHost (prepared, committed and rolled back
/// like any provider), and this object only decides where the mounted ones
/// sit, in the order the Profile lists them.
///
/// The top panel provider may offer a `statusRegion` (an Item it lays out
/// in its own bar); while that panel is shown the items are placed there.
/// A panel that offers none, or no panel at all, gets this Shell-owned strip
/// instead, so a panel provider stays replaceable without knowing about
/// status items. Placing is reparenting: it runs after a commit or a
/// rollback, never per frame, and sends nothing to Core.
///
/// The items are trusted QML in this Shell process (same host, no
/// isolation). Their own timers are theirs; the area runs none.
Scope {
    id: area

    required property var providers
    property string areaName: "ui.status_item"

    /// The Item the mounted items are in now, and whether it is on screen.
    property Item region: null
    readonly property bool regionShown: region !== null
        && (region === stripRow ? strip.visible : (panelProvider !== null && panelProvider.shown === true))
    property var panelProvider: null

    /// The panel's region, while that panel is shown and offers one.
    function panelRegion() {
        const panel = providers.item("ui.panel_top");
        if (panel && panel.shown === true && panel.statusRegion) {
            return { panel: panel, region: panel.statusRegion };
        }
        return null;
    }

    /// Mounted items of the area, in Profile order.
    function mountedItems() {
        const order = providers.areaOrder[areaName] || [];
        const items = [];
        for (const key of order) {
            const unit = providers.slots[key];
            if (unit && unit.active && unit.active.object) {
                items.push(unit.active.object);
            }
        }
        return items;
    }

    function layout() {
        const items = mountedItems();
        const fromPanel = panelRegion();
        // Whatever is not mounted (released, retired, dropped) leaves the bar.
        for (const key in providers.slots) {
            const unit = providers.slots[key];
            if (unit.reportedSlot !== areaName) {
                continue;
            }
            for (const held of [unit.retired, unit.candidate]) {
                if (held && held.object && items.indexOf(held.object) < 0) {
                    held.object.parent = null;
                }
            }
        }
        // Out, then back in order: a Row lays out its children in the order
        // they were added.
        for (const item of items) {
            item.parent = null;
        }
        strip.wanted = fromPanel === null && items.length > 0;
        const target = fromPanel ? fromPanel.region : stripRow;
        panelProvider = fromPanel ? fromPanel.panel : null;
        for (const item of items) {
            item.parent = target;
        }
        region = target;
    }

    /// Readback for one item: placed in the current region, and that region
    /// is on screen.
    function placed(object) {
        return !!object && region !== null && object.parent === region && regionShown;
    }

    PanelWindow {
        id: strip

        property bool wanted: false
        visible: wanted
        screen: area.providers.screen
        anchors { top: true; right: true }
        margins { top: 4; right: 8 }
        implicitWidth: stripRow.implicitWidth + area.providers.tokens.spaceWide * 2
        implicitHeight: 28
        exclusiveZone: 0
        color: "transparent"
        WlrLayershell.namespace: "ditto-status-strip"
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

        Rectangle {
            anchors.fill: parent
            radius: area.providers.tokens.radiusSmall
            color: area.providers.tokens.surface
            border.color: area.providers.tokens.border
            border.width: 1
            opacity: area.providers.tokens.surfaceOpacity
        }

        Row {
            id: stripRow
            anchors.centerIn: parent
            spacing: area.providers.tokens.spaceWide
            Accessible.role: Accessible.StatusBar
            Accessible.name: area.providers.client.t(qsTr("狀態列項目"))
        }
    }
}
