import QtQuick
import DittoStub

// Offscreen content only, as with PanelWindow; no native window semantics.
Rectangle {
    parent: StubDesktop.layer
    width: implicitWidth
    height: implicitHeight
    property string title: ""
    property size minimumSize: Qt.size(0, 0)
    /// The real window's screen (null: not known); #116 caps a candidate
    /// window's height by it.
    property var screen: null
    signal closed()
}
