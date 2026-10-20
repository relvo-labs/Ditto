pragma ComponentBehavior: Bound
import QtQuick

/// #116 candidate segmented control: one of a few options in a recessed
/// track. The selected option is a raised white bead with a small filled
/// marker in front of its label (J3: a bubble ring), so the selection never
/// looks like a primary action and never depends on colour alone. A single
/// option is a static chip (a value, not a choice); a disabled control keeps
/// its bead but greys its labels. Keyboard: one Tab stop (the selected
/// option); Left/Right/Up/Down move, Home/End jump, Enter/Space choose.
/// Moving focus does not choose. `options` is a list of { value, label };
/// `maxWidth` wraps the options onto more lines.
Item {
    id: control

    required property var tokens
    property var options: []
    property var value: null
    property string accessibleName: ""
    property real maxWidth: 0
    /// Shown after a sole option's value, e.g. 「唯一可用」.
    property string soleNote: ""
    /// The side padding of each option (a dense toolbar may use less).
    property int segmentPad: tokens.uiPadCard
    signal chosen(var value)

    readonly property bool sole: options.length === 1
    readonly property int selectedIndex: {
        const wanted = JSON.stringify(value);
        for (let i = 0; i < options.length; i++) {
            if (JSON.stringify(options[i].value) === wanted) return i;
        }
        return -1;
    }
    /// The option that takes Tab: the selected one, else the first.
    readonly property int tabIndex: selectedIndex >= 0 ? selectedIndex : 0

    implicitWidth: sole ? soleChip.implicitWidth : track.width
    implicitHeight: sole ? tokens.uiControlHeight : track.height
    Accessible.role: Accessible.Grouping
    Accessible.name: accessibleName

    function segment(index) {
        return repeater.itemAt(index);
    }
    function focusSegment(index) {
        const count = options.length;
        if (count === 0) return;
        const item = segment(((index % count) + count) % count);
        if (item) item.forceActiveFocus(Qt.TabFocusReason);
    }

    // ---- a sole option: a static value ---------------------------------------------
    Row {
        id: soleChip
        objectName: "segmentSoleChip"
        visible: control.sole
        height: control.tokens.uiControlHeight
        spacing: control.tokens.uiGap
        Accessible.role: Accessible.StaticText
        Accessible.name: control.sole ? control.options[0].label + (control.soleNote.length > 0 ? " · " + control.soleNote : "") : ""

        // A value, not a control: plain ink text, no fill or border.
        Text {
            id: soleLabel
            objectName: "segmentSoleLabel"
            anchors.verticalCenter: parent.verticalCenter
            text: control.sole ? control.options[0].label : ""
            color: control.tokens.uiInk
            font.pixelSize: control.tokens.uiFontBody
            font.weight: Font.Medium
        }
        Rectangle {
            visible: control.soleNote.length > 0
            anchors.verticalCenter: parent.verticalCenter
            width: soleNote.implicitWidth + control.tokens.uiGap * 2
            height: soleNote.implicitHeight + 4
            radius: height / 2
            color: control.tokens.uiTrack
            Text {
                id: soleNote
                anchors.centerIn: parent
                text: control.soleNote
                color: control.tokens.uiInkMuted
                font.pixelSize: control.tokens.uiFontCaption
            }
        }
    }

    // ---- the track -------------------------------------------------------------------
    Rectangle {
        id: track
        visible: !control.sole
        readonly property int pad: 3
        width: flow.childrenRect.width + pad * 2
        height: flow.childrenRect.height + pad * 2
        radius: control.tokens.uiJ1 ? control.tokens.uiRadiusControl + pad : Math.min(height / 2, (control.tokens.uiControlHeight + pad * 2) / 2)
        color: control.enabled ? control.tokens.uiTrack : Qt.lighter(control.tokens.uiTrack, 1.02)
        border.color: control.tokens.uiJ3 && control.tokens.uiGloss ? control.tokens.uiBeadEdge : "transparent"
        border.width: 1

        Flow {
            id: flow
            x: track.pad
            y: track.pad
            width: control.maxWidth > 0 ? control.maxWidth - track.pad * 2 : 100000
            spacing: 2

            Repeater {
                id: repeater
                model: control.sole ? [] : control.options

                Item {
                    id: segment
                    required property var modelData
                    required property int index
                    readonly property bool selected: index === control.selectedIndex
                    objectName: "segment_" + index
                    width: segmentLabel.implicitWidth + control.segmentPad * 2 + (dot.visible || control.tokens.uiJ3 ? dot.width + control.tokens.uiGap : 0)
                    height: control.tokens.uiControlHeight
                    activeFocusOnTab: control.enabled && index === control.tabIndex
                    Accessible.role: Accessible.RadioButton
                    Accessible.name: modelData.label
                    Accessible.checked: selected
                    Accessible.onPressAction: if (control.enabled) control.chosen(modelData.value)
                    Keys.onSpacePressed: if (control.enabled) control.chosen(modelData.value)
                    Keys.onReturnPressed: if (control.enabled) control.chosen(modelData.value)
                    Keys.onEnterPressed: if (control.enabled) control.chosen(modelData.value)
                    Keys.onRightPressed: control.focusSegment(index + 1)
                    Keys.onDownPressed: control.focusSegment(index + 1)
                    Keys.onLeftPressed: control.focusSegment(index - 1)
                    Keys.onUpPressed: control.focusSegment(index - 1)
                    Keys.onPressed: event => {
                        if (event.key === Qt.Key_Home) { control.focusSegment(0); event.accepted = true; }
                        else if (event.key === Qt.Key_End) { control.focusSegment(control.options.length - 1); event.accepted = true; }
                    }

                    Rectangle {
                        visible: !segment.selected && hover.containsMouse && control.enabled
                        anchors.fill: parent
                        radius: control.tokens.uiJ1 ? control.tokens.uiRadiusControl : height / 2
                        color: control.tokens.uiGhostHover
                    }

                    JellySurface {
                        objectName: "segmentBead_" + segment.index
                        visible: segment.selected
                        anchors.fill: parent
                        tokens: control.tokens
                        radius: control.tokens.uiJ1 ? control.tokens.uiRadiusControl : height / 2
                        fill: control.tokens.uiJ3 ? control.tokens.uiFill("#ffffff", 0.88) : control.tokens.uiSelectFill
                        edge: control.tokens.uiBeadEdge
                        raised: control.enabled
                        lift: control.tokens.uiJ2 ? 0.7 : 0.45
                        iris: control.tokens.uiJ3
                    }

                    /// The selection marker: a filled bead (J3: a bubble ring).
                    Rectangle {
                        id: dot
                        objectName: "segmentDot_" + segment.index
                        visible: segment.selected
                        width: control.tokens.uiJ3 ? 9 : 7
                        height: width
                        radius: width / 2
                        x: control.segmentPad - 2
                        anchors.verticalCenter: parent.verticalCenter
                        color: control.tokens.uiJ3 ? "transparent" : (control.enabled ? control.tokens.uiSelectDot : control.tokens.uiInkDisabled)
                        border.color: control.enabled ? control.tokens.uiSelectDot : control.tokens.uiInkDisabled
                        border.width: control.tokens.uiJ3 ? 2 : 0
                        Rectangle {
                            visible: control.tokens.uiJ3
                            width: 3; height: 3; radius: 1.5
                            x: 1.5; y: 1.5
                            color: Qt.rgba(1, 1, 1, 0.9)
                        }
                    }

                    Text {
                        id: segmentLabel
                        objectName: "segmentLabel_" + segment.index
                        anchors.verticalCenter: parent.verticalCenter
                        x: dot.visible || control.tokens.uiJ3 ? control.segmentPad + dot.width + control.tokens.uiGap - 2 : control.segmentPad
                        text: segment.modelData.label
                        color: !control.enabled ? control.tokens.uiInkDisabled : control.tokens.uiInk
                        font.pixelSize: control.tokens.uiFontBody
                        font.weight: segment.selected ? Font.DemiBold : Font.Normal
                    }

                    Rectangle {
                        anchors.fill: parent
                        anchors.margins: -2
                        radius: (control.tokens.uiJ1 ? control.tokens.uiRadiusControl : height / 2) + 2
                        color: "transparent"
                        border.color: control.tokens.uiFocus
                        border.width: segment.activeFocus ? 2 : 0
                    }

                    MouseArea {
                        id: hover
                        anchors.fill: parent
                        hoverEnabled: true
                        enabled: control.enabled
                        cursorShape: Qt.PointingHandCursor
                        onClicked: control.chosen(segment.modelData.value)
                    }
                }
            }
        }
    }
}
