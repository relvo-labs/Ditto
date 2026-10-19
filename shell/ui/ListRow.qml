pragma ComponentBehavior: Bound
import QtQuick

/// #116: one row of a GroupedList: a 14 px label (and optional 12 px
/// caption, wrapped) on the left, the row's control on the right, at least
/// `tokens.uiRowHeight` tall. A soft "water line" separates it from the row
/// above. When the control does not fit beside the label it moves under it
/// rather than overflowing. Extra lines (a confirmation, say) go in `below`.
Item {
    id: row

    required property var tokens
    property string label: ""
    property string caption: ""
    /// The trailing control(s).
    default property alias trailing: trail.data
    /// Content under the label row, full width (e.g. a confirm step).
    property alias below: under.data
    property real labelWidth: Math.min(200, width * 0.36)

    readonly property bool firstInGroup: !parent || !parent.visibleChildren || parent.visibleChildren[0] === row
    readonly property bool stacked: trail.childrenRect.width > width - labelWidth - tokens.uiGap * 2

    width: parent ? parent.width : 400
    implicitHeight: Math.max(tokens.uiRowHeight, content.height + tokens.uiGap * 2)
    height: implicitHeight
    Accessible.role: Accessible.Grouping
    Accessible.name: label

    Rectangle {
        objectName: "listRowSeparator"
        visible: !row.firstInGroup
        anchors.left: parent.left
        anchors.right: parent.right
        y: -Math.round(row.tokens.uiGap * 0.75)
        height: 1
        gradient: Gradient {
            orientation: Gradient.Horizontal
            GradientStop { position: 0.0; color: "transparent" }
            GradientStop { position: 0.12; color: row.tokens.uiSeparator }
            GradientStop { position: 0.88; color: row.tokens.uiSeparator }
            GradientStop { position: 1.0; color: "transparent" }
        }
    }

    Column {
        id: content
        y: row.tokens.uiGap
        width: row.width
        spacing: row.tokens.uiGap

        Item {
            width: content.width
            height: row.stacked ? labels.height + row.tokens.uiGap + trail.childrenRect.height
                : Math.max(labels.height, trail.childrenRect.height, row.tokens.uiRowHeight - row.tokens.uiGap * 2)

            Column {
                id: labels
                width: row.stacked ? content.width : row.labelWidth
                anchors.verticalCenter: row.stacked ? undefined : parent.verticalCenter
                spacing: 2
                Text {
                    width: parent.width
                    wrapMode: Text.WordWrap
                    text: row.label
                    color: row.tokens.uiInk
                    font.pixelSize: row.tokens.uiFontLabel
                    font.weight: Font.Medium
                }
                Text {
                    visible: row.caption.length > 0
                    width: parent.width
                    wrapMode: Text.WordWrap
                    text: row.caption
                    color: row.tokens.uiInkMuted
                    font.pixelSize: row.tokens.uiFontCaption
                }
            }

            Item {
                id: trail
                x: row.stacked ? 0 : content.width - childrenRect.width
                y: row.stacked ? labels.height + row.tokens.uiGap : (parent.height - childrenRect.height) / 2
                width: childrenRect.width
                height: childrenRect.height
            }
        }

        Column {
            id: under
            visible: children.length > 0
            width: content.width
            spacing: row.tokens.uiGap
        }
    }
}
