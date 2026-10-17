pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Wayland
import "templates" as Templates

// Fixed trusted interpreter. Core only sends a validated data description;
// package QML is never loaded for a generated provider.
Scope {
    id: provider
    property var client: null
    property var tokens: null
    property var config: ({})
    property var screen: null
    property string slotName: ""
    property string entryId: ""
    property bool shown: false
    property int placementX: 0
    property int placementY: 72
    property int maximumPanelHeight: screen ? Math.floor(screen.height*0.65) : 600
    property bool watching: false
    property string notice: ""
    property string lastRequestedWorkspace: ""
    readonly property var description: config.description || {}
    readonly property bool isTasks: (description.content || {}).template === "tasks_summary_v1"
    readonly property string reservedEdge: "none"
    readonly property bool ready: body.item !== null && body.item.ready === true
    readonly property bool surfaceVisible: surface.visible
    readonly property int panelWidth: description.width || 320
    readonly property int panelHeight: body.item ? body.item.implicitHeight : 120

    function observation() {
        const buttons=[];
        function visit(node) {
            if (!node) return;
            if ((node.objectName || "").indexOf("workspaceAction_")===0) {
                const point=node.mapToItem(body.item,node.width/2,node.height/2);
                buttons.push({workspace_id:node.modelData.workspace_id,enabled:node.enabled,x:(provider.screen ? provider.screen.width : panelWidth)-panelWidth-surface.margins.right+point.x,y:surface.margins.top+point.y});
            }
            for (const child of (node.children || [])) visit(child);
        }
        if (!isTasks) visit(body.item);
        return {artifact_id: config.artifact_id,shown:shown,ready:ready,title:description.title,width:panelWidth,data_available:body.item ? body.item.dataAvailable===true : false,tasks:body.item && isTasks ? body.item.displayedTasks : [],template:(description.content||{}).template,buttons:buttons,notice:notice,last_requested_workspace:lastRequestedWorkspace};
    }

    function healthy() {
        return ready && !!client && !!tokens && (isTasks || (description.content || {}).template === "workspace_actions_v1");
    }
    function release() { shown = false; }
    function watch() {
        if (shown && isTasks && !watching && client) { client.watchTasks(); watching = true; }
        else if ((!shown || !isTasks) && watching && client) { client.unwatchTasks(); watching = false; }
    }
    onShownChanged: watch()
    Component.onDestruction: { if (watching && client) client.unwatchTasks(); }

    property Component tasksTemplate: Component {
        Templates.TasksSummary {
            client: provider.client
            config: provider.description
            tasks: provider.client && provider.client.tasks ? provider.client.tasks.tasks : []
            dataAvailable: !!provider.client && provider.client.tasksStatus === "ready"
            testData: !!provider.client && !!provider.client.tasks && provider.client.tasks.demo === true
        }
    }
    property Component workspaceTemplate: Component {
        Templates.WorkspaceActions {
            client: provider.client
            config: provider.description
            availableWorkspaceIds: provider.client ? provider.client.workspaces.map(w => w.id) : []
            actionsAvailable: !!provider.client && provider.client.online && provider.client.capabilityAvailable("desktop.workspaces.activate")
            onActivateWorkspaceRequested: function(workspaceId) {
                provider.lastRequestedWorkspace=workspaceId;
                provider.client.capability("desktop.workspaces.activate", {workspace_id:workspaceId}, function() {provider.notice="";}, function(error) {provider.notice=provider.client.errorText(error);});
            }
        }
    }
    PanelWindow {
        id: surface
        visible: provider.shown
        screen: provider.screen
        anchors { top: true; right: true }
        margins {
            top: Math.max(48,Math.min(provider.placementY,provider.screen ? provider.screen.height-surface.implicitHeight-12 : provider.placementY))
            right: 12+provider.placementX
        }
        exclusionMode: ExclusionMode.Ignore
        exclusiveZone: 0
        implicitWidth: provider.panelWidth
        implicitHeight: Math.min(provider.maximumPanelHeight, provider.panelHeight+(provider.notice.length>0 ? 40 : 0))
        color: "transparent"
        focusable: true
        WlrLayershell.layer: WlrLayer.Top
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand
        WlrLayershell.namespace: "ditto-generated-panel"
        ScrollView {
            anchors.fill: parent
            anchors.bottomMargin: provider.notice.length>0 ? 40 : 0
            clip: true
            contentWidth: availableWidth
            contentHeight: body.height
            Loader {
                id: body
                width: surface.implicitWidth
                height: item ? item.implicitHeight : 120
                sourceComponent: provider.isTasks ? provider.tasksTemplate : provider.workspaceTemplate
            }
        }
        Text {
            anchors {bottom:parent.bottom;left:parent.left;right:parent.right;margins:12}
            visible: provider.notice.length>0
            text: provider.notice
            textFormat: Text.PlainText
            wrapMode: Text.Wrap
            color: provider.tokens ? provider.tokens.warning : "#7B2445"
        }
    }
}
