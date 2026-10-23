import QtQuick
Item {
    required property var client
    required property var tokens
    required property var config
    required property string pageId
    required property string entryId
    // Opt in even with the default undefined value.
    property var aiSettings
}
