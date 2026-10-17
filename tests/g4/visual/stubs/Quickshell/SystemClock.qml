import QtQuick

/// Test double: the real time when the object is created (not a fixed time).
QtObject {
    enum Precision { Hours, Minutes, Seconds }
    property bool enabled: true
    property int precision: SystemClock.Minutes
    property date date: new Date()
}
