pragma Singleton
import QtQuick

/// Test double for the compositor's output: the item layer-shell windows are
/// placed on, and its size. Not part of the product.
QtObject {
    property Item layer: null
    property real screenWidth: 1280
    property real screenHeight: 800
}
