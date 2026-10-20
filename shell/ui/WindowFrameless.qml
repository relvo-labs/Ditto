import QtQuick

/// Whether Qt draws its own title bar on a Ditto window (Qt's
/// FramelessWindowHint): `frameless` while the window's #116 style draws the
/// one title (WindowHeader), Qt's own title bar otherwise. Declared once by
/// the window itself (Centers, ChatWindow, ApprovalWindow), not by the header,
/// so it lives exactly as long as the window.
///
/// The hint changes only while the window is not shown; see the top of
/// WindowHeader.qml for why changing it on a shown window crashes the Shell.
/// - First show: Quickshell attaches the window's items to the backing
///   window and only then shows it, so `Window.onWindowChanged` sets the hint
///   before anything is drawn and the window opens once, as before.
/// - A change while shown (the style turned off or on: theme, undo, the
///   Agent; J1/J2/J3 among themselves change nothing here): the window is
///   hidden through `hostWindow.visible` (for a Quickshell FloatingWindow
///   that is not a close, so nothing is refused or closed), the hint changes,
///   and the window is shown again with its items, focus and content as they
///   were. The compositor places it again.
/// - Only a hint added here is taken away; every other flag is kept.
/// - Closing the window changes nothing: the window goes.
///
/// It acts only on a real window (one with `startSystemMove()`, as a
/// FloatingWindow has); an offscreen double is left alone.
Item {
    id: policy

    /// The FloatingWindow this belongs to. Its `visible` hides and shows it.
    property var hostWindow: null
    property bool frameless: false

    /// The backing window this added the hint to, or null.
    property var addedTo: null

    visible: false
    width: 0
    height: 0

    function sync() {
        const backing = policy.Window.window;
        if (addedTo && addedTo !== backing) addedTo = null;
        if (!backing || backing.flags === undefined) return;
        if (!hostWindow || typeof hostWindow.startSystemMove !== "function") return;
        const has = (backing.flags & Qt.FramelessWindowHint) !== 0;
        let next = backing.flags;
        if (frameless && !has) next = backing.flags | Qt.FramelessWindowHint;
        else if (!frameless && has && addedTo === backing) next = backing.flags & ~Qt.FramelessWindowHint;
        if (next === backing.flags) return;

        if (!backing.visible) {
            write(backing, next);
            return;
        }
        // Shown: hide, change, show again. If hiding did not take (not this
        // window's host), leave the flags as they are.
        hostWindow.visible = false;
        if (!backing.visible) write(backing, next);
        hostWindow.visible = true;
    }
    function write(backing, next) {
        backing.flags = next;
        addedTo = (next & Qt.FramelessWindowHint) !== 0 ? backing : null;
    }

    onFramelessChanged: sync()
    onHostWindowChanged: sync()
    Component.onCompleted: sync()
    Connections {
        target: policy.Window
        function onWindowChanged() { policy.sync(); }
    }
}
