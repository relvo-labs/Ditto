import QtQuick
import QtQuick.Controls as Controls
import "../jelly" as Jelly

/// A labelled button, never a pretend input field. State is a projection of
/// the shared conversation; no subscription, timer or context acquisition here.
Rectangle {
    id: entry
    required property var tokens
    required property var conversation
    required property var client
    property string symbolVariant: "neutral"
    // Opt-in visual candidates only. Shell/Profile defaults remain capsule.
    property string entryStyle: "capsule"
    property int fabSize: 48
    property string expansionMode: "label"
    property bool labelExpanded: false
    readonly property bool labelled: entryStyle !== "fab" || (expansionMode === "label" && labelExpanded)
    property bool expanded: false
    property bool animations: true
    readonly property bool motionEnabled: visible && animations && tokens.motionEnabled
    // Cancelling is still mapped to thinking by the existing seven-state
    // projection. Explicitly exclude it; no progress is inferred from a click.
    readonly property bool working: client.online && !conversation.reconnecting
        && conversation.connected && conversation.turn && conversation.turn.state === "running"
        && ["thinking", "executing"].indexOf(conversation.taskState) >= 0
    // Opening is explicit; a fresh projection must not invent an AI setting.
    // A failed read is not 待命中: the shared text says it could not be read.
    readonly property string statusText: client.online === false
        ? conversation.stateText
        : !conversation.wanted || (conversation.aiStatus === "pending" && !conversation.settings)
            ? client.t(qsTr("待命中")) : conversation.stateText
    signal activated()
    signal collapseRequested()
    function activate() {
        if (entryStyle === "fab" && expansionMode === "label" && !labelExpanded)
            labelExpanded = true;
        else
            activated();
    }
    function collapse() {
        if (entryStyle !== "fab") return;
        labelExpanded = false;
        collapseRequested();
    }
    implicitWidth: !labelled ? fabSize : entryStyle === "fab" ? Math.max(195, label.implicitWidth + 84) : Math.max(218, label.implicitWidth + 84)
    implicitHeight: !labelled ? fabSize : Math.max(entryStyle === "fab" ? fabSize : 54, label.implicitHeight + status.implicitHeight + 12)
    radius: height / 2
    color: area.containsMouse ? tokens.surfaceStrong : tokens.surface
    border.color: activeFocus ? tokens.focus : tokens.border
    border.width: activeFocus ? 2 : 1
    activeFocusOnTab: true
    Accessible.role: Accessible.Button
    Accessible.name: !labelled && expansionMode === "label" ? client.t(qsTr("展開助理")) : client.t(qsTr("開啟助理對話"))
    Accessible.description: status.text
    Accessible.onPressAction: entry.activate()
    Keys.onReturnPressed: entry.activate()
    Keys.onEnterPressed: entry.activate()
    Keys.onSpacePressed: entry.activate()
    Keys.onEscapePressed: event => {
        if (entry.entryStyle === "fab") {
            entry.collapse();
            event.accepted = true;
        } else event.accepted = false;
    }
    Controls.ToolTip.visible: entry.entryStyle === "fab" && !entry.labelled && (area.containsMouse || entry.activeFocus)
    Controls.ToolTip.text: entry.statusText
    Controls.ToolTip.delay: 0

    AssistantSymbol {
        id: symbol
        x: entry.entryStyle === "fab" ? (entry.labelled ? (entry.height - width) / 2 : (entry.width - width) / 2) : 12
        width: entry.entryStyle === "fab" ? 35 : 32
        height: width
        anchors.verticalCenter: parent.verticalCenter
        tokens: entry.tokens
        variant: entry.symbolVariant
        scale: feedback.value * presentation.value
        opacity: entry.working ? entry.workLevel : 1
    }
    Jelly.MotionValue {
        id: presentation
        value: 0.96
        active: entry.motionEnabled
        duration: entry.tokens.motionPresent
    }
    Jelly.MotionValue {
        id: feedback
        targetValue: !entry.visible ? 1 : area.pressed ? 0.90
            : area.containsMouse || entry.activeFocus ? 0.96 : entry.expanded ? 0.98 : 1
        active: entry.motionEnabled
        duration: entry.tokens.motionFeedback
    }
    // Only the glyph changes, inside the unchanged capsule/input region.
    property real workLevel: 1
    SequentialAnimation {
        id: workCue
        running: entry.motionEnabled && entry.working
        loops: Animation.Infinite
        NumberAnimation { target: entry; property: "workLevel"; to: 0.65; duration: 650; easing.type: Easing.InOutQuad }
        NumberAnimation { target: entry; property: "workLevel"; to: 1; duration: 650; easing.type: Easing.InOutQuad }
        onRunningChanged: if (!running) entry.workLevel = 1
    }
    readonly property bool workingCueRunning: workCue.running
    readonly property bool feedbackRunning: feedback.running
    function settleMotion() {
        feedback.settle();
        presentation.settle();
    }
    Column {
        visible: entry.labelled
        x: entry.entryStyle === "fab" ? entry.height : 54
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width - x - 16
        Text {
            id: label
            text: entry.client.t(qsTr("助理"))
            color: entry.tokens.foreground
            font.pixelSize: entry.tokens.fontBody
            font.weight: Font.DemiBold
        }
        Text {
            id: status
            width: parent.width
            text: entry.statusText + (entry.conversation.transportText ? " · " + entry.conversation.transportText : "")
            color: entry.tokens.foregroundMuted
            font.pixelSize: entry.tokens.fontSmall
            elide: Text.ElideRight
        }
    }
    MouseArea {
        id: area
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        // Same rounded shape as the surface input region.
        containmentMask: QtObject {
            function contains(point: point): bool {
                const r = entry.height / 2;
                const x = Math.max(r, Math.min(entry.width - r, point.x));
                return Math.pow(point.x - x, 2) + Math.pow(point.y - r, 2) <= r * r;
            }
        }
        onClicked: entry.activate()
    }
}
