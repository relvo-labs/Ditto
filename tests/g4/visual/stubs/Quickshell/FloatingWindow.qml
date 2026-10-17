import QtQuick
import DittoStub

// Offscreen content only, as with PanelWindow; no native window semantics.
Rectangle {
    parent: StubDesktop.layer
    width: implicitWidth
    height: implicitHeight
    property string title: ""
    property size minimumSize: Qt.size(0, 0)
    signal closed()
}
