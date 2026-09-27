import QtQuick

/// A segmented choice: one of a few options, each a button. `options` is a
/// list of { value, label }. With `maxWidth` set, the options wrap onto more
/// lines instead of running past the edge.
Item {
    id: choice

    required property var tokens
    property var options: []
    property var value: null
    property string accessibleName: ""
    property real maxWidth: 0
    signal chosen(var value)

    implicitWidth: flow.childrenRect.width
    implicitHeight: flow.childrenRect.height
    Accessible.role: Accessible.Grouping
    Accessible.name: accessibleName

    Flow {
        id: flow
        width: choice.maxWidth > 0 ? choice.maxWidth : 100000
        spacing: 4

        Repeater {
            model: choice.options

            Rectangle {
                required property var modelData
                readonly property bool selected: JSON.stringify(modelData.value) === JSON.stringify(choice.value)
                width: optionLabel.implicitWidth + choice.tokens.spaceWide * 2
                height: choice.tokens.controlHeight
                radius: choice.tokens.radiusSmall
                color: selected ? choice.tokens.accent : choice.tokens.surfaceStrong
                border.color: activeFocus ? choice.tokens.focus : choice.tokens.border
                border.width: activeFocus ? 2 : 1
                opacity: choice.enabled ? 1 : 0.45
                activeFocusOnTab: choice.enabled
                Accessible.role: Accessible.RadioButton
                Accessible.name: optionLabel.text
                Accessible.checked: selected
                Keys.onSpacePressed: choice.chosen(modelData.value)
                Keys.onReturnPressed: choice.chosen(modelData.value)

                Text {
                    id: optionLabel
                    anchors.centerIn: parent
                    text: modelData.label + (parent.selected ? " ✓" : "")
                    color: parent.selected ? choice.tokens.onAccent : choice.tokens.foreground
                    font.pixelSize: choice.tokens.fontBody
                }

                MouseArea {
                    anchors.fill: parent
                    onClicked: choice.chosen(modelData.value)
                }
            }
        }
    }
}
