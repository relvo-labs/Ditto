import QtQuick
import Quickshell
import "../ui"
import "../change"

/// The conversation window (M1's minimal chat entry, G2-SHELL-01/04 subset).
/// It shows what Core holds: the user's accepted messages, the answers, and
/// for every desktop change the Core change card with its verified state.
/// A model's own words never stand in for a result: "done" is the card.
///
/// Closing the window only hides it; a running turn keeps going in Core and
/// is stopped only by 「停止」.
FloatingWindow {
    id: window

    required property var client
    required property var tokens
    required property var conversation
    signal closeRequested()

    function t(source) {
        return client.t(source);
    }

    title: t(qsTr("Ditto 對話"))
    implicitWidth: 560
    implicitHeight: 680
    minimumSize: Qt.size(420, 420)
    color: tokens.background
    visible: true
    onClosed: window.closeRequested()

    /// Change records by id, read once per card from Core.
    property var records: ({})
    function record(changeId) {
        if (records[changeId] !== undefined) {
            return records[changeId];
        }
        records[changeId] = null;
        client.capability("desktop.changes.get", { change_id: changeId }, function (result) {
            const table = Object.assign({}, window.records);
            table[changeId] = result;
            window.records = table;
        });
        return null;
    }
    Connections {
        target: window.client
        function onChangeUpdated(change) {
            if (window.records[change.change_id] !== undefined) {
                const table = Object.assign({}, window.records);
                table[change.change_id] = change;
                window.records = table;
            }
        }
    }

    readonly property var visibleEvents: conversation.events.filter(event =>
        event.type === "user/message" || event.type === "assistant/message"
        || (event.type === "tool/result" && event.data && event.data.change_id))

    Item {
        id: chatRoot
        anchors.fill: parent
        focus: true
        Keys.onEscapePressed: window.closeRequested()

        Column {
            id: header
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: window.tokens.spaceWide
            spacing: window.tokens.space

            Row {
                width: parent.width
                spacing: window.tokens.space
                Text {
                    text: window.t(qsTr("Ditto 對話"))
                    color: window.tokens.foreground
                    font.pixelSize: window.tokens.fontTitle
                    font.weight: Font.DemiBold
                    anchors.verticalCenter: parent.verticalCenter
                }
                Badge {
                    tokens: window.tokens
                    text: window.conversation.stateText
                    tone: window.conversation.taskState === "failed" ? "bad"
                        : window.conversation.taskState === "done" ? "good"
                        : window.conversation.taskState === "offline" ? "neutral" : "info"
                    anchors.verticalCenter: parent.verticalCenter
                    Accessible.role: Accessible.StaticText
                    Accessible.name: window.conversation.stateText
                }
            }

            // AI off: the desktop works without it; turning it on is explicit.
            Row {
                visible: window.client.online && !!window.conversation.settings && !window.conversation.enabled
                spacing: window.tokens.space
                Text {
                    text: window.t(qsTr("AI 對話目前關閉。開啟後才會連接模型。"))
                    color: window.tokens.foregroundMuted
                    font.pixelSize: window.tokens.fontBody
                    anchors.verticalCenter: parent.verticalCenter
                }
                Button {
                    tokens: window.tokens
                    kind: "primary"
                    text: window.t(qsTr("開啟 AI 對話"))
                    onClicked: window.conversation.setEnabled(true)
                }
            }

            // Signed out: the official browser sign-in of the Codex
            // subscription. No API key field on this path.
            Column {
                visible: window.conversation.enabled && !window.conversation.connected
                    && window.conversation.taskState !== "starting"
                width: parent.width
                spacing: window.tokens.spaceTight
                Text {
                    width: parent.width
                    wrapMode: Text.WordWrap
                    text: window.conversation.login
                        ? window.t(qsTr("請在瀏覽器完成登入。完成後這裡會自動更新。"))
                        : window.t(qsTr("使用你的 Codex 訂閱登入後即可對話。不會改用付費 API。"))
                    color: window.tokens.foregroundMuted
                    font.pixelSize: window.tokens.fontBody
                }
                Row {
                    spacing: window.tokens.space
                    Button {
                        visible: !window.conversation.login
                        tokens: window.tokens
                        kind: "primary"
                        text: window.t(qsTr("使用 Codex 訂閱登入"))
                        onClicked: window.conversation.startLogin()
                    }
                    Button {
                        visible: !!window.conversation.login
                        tokens: window.tokens
                        text: window.t(qsTr("重新開啟登入頁"))
                        onClicked: Qt.openUrlExternally(window.conversation.login.auth_url)
                    }
                    Button {
                        visible: !!window.conversation.login
                        tokens: window.tokens
                        kind: "subtle"
                        text: window.t(qsTr("取消登入"))
                        onClicked: window.conversation.cancelLogin()
                    }
                }
            }

            Text {
                visible: window.conversation.connected
                width: parent.width
                elide: Text.ElideRight
                text: {
                    const provider = window.conversation.provider;
                    if (!provider) {
                        return "";
                    }
                    const account = provider.account_label || window.t(qsTr("已登入"));
                    const limits = provider.rate_limits;
                    const used = limits && limits.primary ? window.t(qsTr("額度已用 %1%")).arg(Math.round(limits.primary.used_percent))
                        : window.t(qsTr("尚無配額資料"));
                    return account + "  ·  " + used;
                }
                color: window.tokens.foregroundMuted
                font.pixelSize: window.tokens.fontSmall
            }
        }

        ListView {
            id: list
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: header.bottom
            anchors.bottom: composer.top
            anchors.margins: window.tokens.spaceWide
            clip: true
            spacing: window.tokens.space
            model: window.visibleEvents
            // New events keep the view at the end, unless the user scrolled up.
            onCountChanged: if (atYEnd || count < 3) Qt.callLater(positionViewAtEnd)
            Accessible.role: Accessible.List
            Accessible.name: window.t(qsTr("對話內容"))

            delegate: Item {
                id: row
                required property var modelData
                width: list.width
                height: row.modelData.type === "tool/result" ? card.implicitHeight + window.tokens.space * 2 : bubble.implicitHeight + window.tokens.space * 2
                readonly property bool mine: row.modelData.type === "user/message"

                Rectangle {
                    id: bubble
                    visible: row.modelData.type !== "tool/result"
                    width: Math.min(row.width * 0.85, message.implicitWidth + window.tokens.spaceWide * 2)
                    implicitHeight: message.implicitHeight + window.tokens.space * 2
                    anchors.right: row.mine ? parent.right : undefined
                    anchors.left: row.mine ? undefined : parent.left
                    radius: window.tokens.radiusSmall
                    color: row.mine ? window.tokens.surfaceStrong : window.tokens.surface
                    border.color: window.tokens.border

                    Text {
                        id: message
                        anchors.fill: parent
                        anchors.margins: window.tokens.space
                        anchors.leftMargin: window.tokens.spaceWide
                        anchors.rightMargin: window.tokens.spaceWide
                        width: row.width * 0.85 - window.tokens.spaceWide * 2
                        wrapMode: Text.Wrap
                        textFormat: Text.PlainText
                        text: row.modelData.data && typeof row.modelData.data.text === "string" ? row.modelData.data.text : ""
                        color: window.tokens.foreground
                        font.pixelSize: window.tokens.fontBody
                        Accessible.role: Accessible.StaticText
                        Accessible.name: (row.mine ? window.t(qsTr("你：")) : window.t(qsTr("Ditto："))) + text
                    }
                }

                ChangeCard {
                    id: card
                    visible: row.modelData.type === "tool/result"
                    width: row.width
                    client: window.client
                    tokens: window.tokens
                    record: row.modelData.type === "tool/result" ? window.record(row.modelData.data.change_id) : null
                }
            }
        }

        Column {
            id: composer
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.margins: window.tokens.spaceWide
            spacing: window.tokens.space

            Text {
                visible: window.conversation.errorText.length > 0
                width: parent.width
                wrapMode: Text.WordWrap
                text: window.conversation.errorText
                color: window.tokens.danger
                font.pixelSize: window.tokens.fontSmall
            }

            Diagnostics {
                width: parent.width
                tokens: window.tokens
                title: window.t(qsTr("診斷"))
                text: window.conversation.errorDiagnostic
            }

            Row {
                width: parent.width
                spacing: window.tokens.space

                TextField {
                    id: input
                    width: parent.width - send.width - stop.width - fresh.width - window.tokens.space * 3
                    tokens: window.tokens
                    placeholder: window.t(qsTr("描述想調整的桌面，例如「開啟通知專注模式」"))
                    accessibleName: window.t(qsTr("訊息"))
                    enabled: window.conversation.enabled && window.conversation.connected
                    text: window.conversation.draft
                    onTextChanged: window.conversation.draft = text
                    onAccepted: window.conversation.send()
                }
                Button {
                    id: send
                    tokens: window.tokens
                    kind: "primary"
                    text: window.conversation.sending ? window.t(qsTr("送出中")) : window.t(qsTr("送出"))
                    enabled: window.conversation.connected && !window.conversation.turnActive
                        && !window.conversation.sending && window.conversation.draft.trim().length > 0
                    onClicked: window.conversation.send()
                }
                Button {
                    id: stop
                    tokens: window.tokens
                    kind: "danger"
                    visible: window.conversation.turnActive
                    width: visible ? implicitWidth : 0
                    text: window.t(qsTr("停止"))
                    onClicked: window.conversation.stop()
                }
                Button {
                    id: fresh
                    tokens: window.tokens
                    kind: "subtle"
                    text: window.t(qsTr("新對話"))
                    enabled: !window.conversation.turnActive
                    onClicked: window.conversation.newConversation()
                }
            }
        }

        Component.onCompleted: input.focusInput()
    }
}
