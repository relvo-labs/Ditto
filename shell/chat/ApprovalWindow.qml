import QtQuick
import Quickshell
import "../ui"

/// One approval request from the Agent (G2-CORE-02's Shell side). What it
/// asks is described from Core's record of the request — the capability and
/// its resource scope — never from the model's own wording, which appears
/// only in the diagnostics as an unverified note. 「允許這一次」 allows that
/// one bound tool call; nothing here creates a lasting grant.
FloatingWindow {
    id: window

    required property var client
    required property var tokens
    required property var approval
    signal decided(string decision)

    function t(source) {
        return client.t(source);
    }

    readonly property var request: approval ? approval.request : ({})
    readonly property string resource: request.resource || ""

    /// What the request would let the Agent do, by resource scope.
    function scopeText(scope) {
        switch (scope) {
        case "desktop.config":
            return t(qsTr("變更桌面設定"));
        case "profiles.delete":
            // The name is Core's reading of the bound call, not the model's.
            return window.approval && window.approval.target
                ? t(qsTr("永久刪除設定檔「%1」，刪除後無法復原")).arg(window.approval.target)
                : t(qsTr("永久刪除一個設定檔，刪除後無法復原"));
        case "desktop.windows.read":
            return t(qsTr("查看目前開啟的視窗、工作區與螢幕"));
        case "desktop.windows.control":
            return t(qsTr("移動、調整大小、切換或要求關閉視窗"));
        case "notifications.read":
            return t(qsTr("讀取通知內容"));
        case "tasks.read":
            return t(qsTr("讀取待辦事項"));
        case "tasks.write":
            return t(qsTr("新增或完成待辦事項"));
        case "apps.launch":
            return t(qsTr("開啟應用程式"));
        case "plugins.manage":
            return t(qsTr("安裝或管理插件"));
        case "session.lock":
            return t(qsTr("鎖定螢幕"));
        }
        return t(qsTr("使用一項桌面能力"));
    }

    title: t(qsTr("Ditto 需要你的確認"))
    implicitWidth: 460
    implicitHeight: 300
    color: tokens.background
    visible: true
    onClosed: window.decided("rejected")

    /// The control with keyboard focus, for the Shell's `focus` line.
    readonly property Item focusedItem: approvalRoot.Window.activeFocusItem

    Item {
        id: approvalRoot
        anchors.fill: parent
        focus: true
        Keys.onEscapePressed: window.decided("rejected")

        Column {
            anchors.fill: parent
            anchors.margins: window.tokens.spaceWide
            spacing: window.tokens.space
            Accessible.role: Accessible.Grouping
            Accessible.name: window.t(qsTr("確認請求"))

            Text {
                width: parent.width
                wrapMode: Text.WordWrap
                text: window.t(qsTr("Ditto 想在這次對話中做一件需要你同意的事："))
                color: window.tokens.foreground
                font.pixelSize: window.tokens.fontBody
            }

            Repeater {
                model: window.resource.split(",").filter(scope => scope.length > 0)
                Text {
                    required property var modelData
                    width: parent.width
                    wrapMode: Text.WordWrap
                    text: "•  " + window.scopeText(modelData)
                    color: window.tokens.foreground
                    font.pixelSize: window.tokens.fontTitle
                }
            }

            Text {
                width: parent.width
                wrapMode: Text.WordWrap
                text: window.t(qsTr("只允許這一次；下次需要時會再問。拒絕不會影響目前的桌面。"))
                color: window.tokens.foregroundMuted
                font.pixelSize: window.tokens.fontSmall
            }

            Row {
                spacing: window.tokens.space
                Button {
                    id: allow
                    tokens: window.tokens
                    kind: "primary"
                    text: window.t(qsTr("允許這一次"))
                    onClicked: window.decided("allowed-once")
                }
                Button {
                    id: reject
                    tokens: window.tokens
                    text: window.t(qsTr("拒絕"))
                    onClicked: window.decided("rejected")
                }
            }

            Diagnostics {
                width: parent.width
                tokens: window.tokens
                title: window.t(qsTr("診斷"))
                text: window.approval
                    ? window.request.capability_id + "\n" + window.resource + "\n"
                        + window.t(qsTr("Agent 的說明（未經驗證）：")) + window.request.purpose + "\n" + window.approval.request_id
                    : ""
            }
        }

        // Refusing is the safe default under the keyboard.
        Component.onCompleted: reject.forceActiveFocus()
    }
}
