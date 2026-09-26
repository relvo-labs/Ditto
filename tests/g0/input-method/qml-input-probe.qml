import QtQuick
import QtQuick.Window
import Quickshell

/// C-08 QML fixture. The caret is deliberately far from the top-left corner,
/// so the screenshot can distinguish a popup positioned at the caret from one
/// incorrectly placed at (0, 0). Text is reported from the control itself;
/// seeing key events in an input-method log is not accepted as a commit.
ShellRoot {
    Window {
        id: window

        visible: true
        width: 720
        height: 260
        title: "Ditto input method probe"
        color: "#171923"

        Column {
            anchors.fill: parent
            anchors.margins: 32
            spacing: 20

            Text {
                color: "#f2f3f8"
                font.pixelSize: 20
                text: "中文輸入鏈路測試"
            }

            Rectangle {
                width: parent.width
                height: 64
                radius: 8
                color: "#242739"
                border.color: input.activeFocus ? "#b7a6ff" : "#3a3f55"
                border.width: 2

                TextInput {
                    id: input
                    anchors.fill: parent
                    anchors.margins: 14
                    color: "#f2f3f8"
                    selectionColor: "#6f5fc7"
                    font.pixelSize: 24
                    focus: true
                    activeFocusOnTab: true
                    inputMethodHints: Qt.ImhNone

                    onInputMethodComposingChanged: {
                        if (inputMethodComposing)
                            console.log("DITTO_INPUT_COMPOSING " + cursorRectangle.x + "," + cursorRectangle.y);
                    }

                    onAccepted: {
                        console.log("DITTO_INPUT_RESULT " + JSON.stringify({
                            text: text,
                            cursor_position: cursorPosition,
                            active_focus: activeFocus
                        }));
                    }
                }
            }

            Text {
                color: "#a9aec4"
                font.pixelSize: 14
                text: "候選字視窗應貼近上方輸入游標，不應出現在畫面左上角。"
            }
        }

        Component.onCompleted: {
            input.forceActiveFocus();
            console.log("DITTO_INPUT_READY");
        }
    }
}
