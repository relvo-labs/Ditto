import QtQuick

/// Test double: a non-visual container, as Quickshell's Scope.
QtObject {
    id: scope
    default property list<QtObject> data
    /// Quickshell 0.3.1 exposes the same list as `children` (its default property).
    readonly property alias children: scope.data
}
