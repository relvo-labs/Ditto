pragma Singleton
import QtQuick

/// Test double for Quickshell's singleton (the real module needs a Wayland
/// session). `env` reads `environment`; `iconPath` looks the name up in
/// `iconMap`, which the harness fills from the icon theme on disk, and
/// returns "" for an unknown name, as `iconPath(name, true)` does.
QtObject {
    property var environment: ({})
    property var iconMap: ({})
    property var screens: []

    function env(name) {
        return environment[name] === undefined ? undefined : environment[name];
    }

    function iconPath(icon, check) {
        const path = iconMap[icon];
        return path ? path : "";
    }
}
