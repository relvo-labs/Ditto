import QtQuick
import QtQuick.Dialogs
import Quickshell
import "../ui"
import "../change"

/// The chat itself (G2-SHELL-01): header, conversation, composer. The full
/// window and the compact panel beside the character both show this, over
/// the one ConversationState, so switching keeps draft, history, stream and
/// task (AVA-03/06).
/// It shows what Core holds: the user's accepted messages, the answers, and
/// for every desktop change the Core change card with its verified state.
/// A model's own words never stand in for a result: "done" is the card.
///
/// Closing the window only hides it; a running turn keeps going in Core and
/// is stopped only by 「停止」.
Item {
    id: window

    required property var client
    required property var tokens
    required property var conversation
    /// The panel beside the character: fewer controls, same content.
    property bool compact: false
    signal closeRequested()
    signal expandRequested()
    signal collapseRequested()
    signal settingsRequested()

    function t(source) {
        return client.t(source);
    }

    function focusInput() {
        input.focusInput();
    }

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
                    width: Math.min(implicitWidth, window.width * 0.5)
                    text: window.conversation.stateText
                    tone: window.conversation.taskState === "failed" ? "bad"
                        : window.conversation.taskState === "done" ? "good"
                        : window.conversation.taskState === "offline" ? "neutral" : "info"
                    anchors.verticalCenter: parent.verticalCenter
                    Accessible.role: Accessible.StaticText
                    Accessible.name: window.conversation.stateText
                }
            }

            Row {
                spacing: window.tokens.spaceTight
                Button {
                    tokens: window.tokens
                    kind: "subtle"
                    text: window.compact ? window.t(qsTr("展開")) : window.t(qsTr("收合"))
                    accessibleName: window.compact ? window.t(qsTr("展開成完整視窗")) : window.t(qsTr("收合到角色旁"))
                    onClicked: window.compact ? window.expandRequested() : window.collapseRequested()
                }
                Button {
                    tokens: window.tokens
                    kind: "subtle"
                    text: window.t(qsTr("歷史"))
                    onClicked: history.open = !history.open
                }
                Button {
                    tokens: window.tokens
                    kind: "subtle"
                    text: window.t(qsTr("AI 設定"))
                    onClicked: window.settingsRequested()
                }
            }

            // Earlier conversations: pick one to read or continue; delete
            // keeps the desktop as it is (changes are not undone).
            Column {
                id: history
                property bool open: false
                visible: open
                width: parent.width
                spacing: window.tokens.spaceTight
                Repeater {
                    model: history.open ? window.conversation.sessions.slice(0, 12) : []
                    Row {
                        required property var modelData
                        spacing: window.tokens.spaceTight
                        Button {
                            tokens: window.tokens
                            kind: modelData.session_id === window.conversation.sessionId ? "secondary" : "subtle"
                            text: (modelData.title || window.t(qsTr("對話"))) + "  " + modelData.created_at.slice(5, 16).replace("T", " ")
                            onClicked: { window.conversation.selectSession(modelData.session_id, modelData.next_seq); history.open = false; }
                        }
                        Button {
                            tokens: window.tokens
                            kind: "subtle"
                            text: "✕"
                            accessibleName: window.t(qsTr("刪除這段對話（桌面維持原樣）"))
                            enabled: modelData.session_id !== window.conversation.sessionId || !window.conversation.turnActive
                            onClicked: window.conversation.deleteSession(modelData.session_id)
                        }
                    }
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
                Button {
                    tokens: window.tokens
                    kind: "subtle"
                    text: window.t(qsTr("先不要"))
                    onClicked: window.closeRequested()
                }
            }

            // Signed out: the official device-code sign-in of the Codex
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
                        ? window.t(qsTr("在瀏覽器開啟的頁面登入，並輸入下方代碼。完成後這裡會自動更新。"))
                        : window.t(qsTr("使用你的 Codex 訂閱登入後即可對話。不會改用付費 API。"))
                    color: window.tokens.foregroundMuted
                    font.pixelSize: window.tokens.fontBody
                }
                TextEdit {
                    visible: !!window.conversation.login
                    readOnly: true
                    selectByMouse: true
                    text: window.conversation.login ? window.conversation.login.user_code : ""
                    color: window.tokens.foreground
                    font.pixelSize: window.tokens.fontTitle
                    font.family: "monospace"
                    font.letterSpacing: 2
                    Accessible.role: Accessible.StaticText
                    Accessible.name: window.t(qsTr("登入代碼")) + " " + text
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

        // First steps (G2-SHELL-06): three real things to try, each offered
        // only when this desktop can do it; otherwise it says what is missing.
        Column {
            id: examples
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: header.bottom
            anchors.margins: window.tokens.spaceWide
            visible: window.conversation.connected && window.visibleEvents.length === 0 && !window.conversation.turnActive
            spacing: window.tokens.spaceTight
            readonly property bool pill: (window.client.packages || []).some(p => p.package_id === "ditto.dock.pill")
            readonly property var items: [
                { text: window.t(qsTr("把 Dock 移到左邊")), ok: examples.pill, why: window.t(qsTr("需要已安裝的膠囊 Dock")) },
                { text: window.t(qsTr("幫我做專注工作區，通知安靜一點")), ok: window.client.capabilityAvailable("desktop.notifications.policy.get") && window.client.capabilityAvailable("desktop.layout.get"), why: window.t(qsTr("通知規則服務目前不可用")) },
                { text: window.t(qsTr("把現在的桌面保存成一個新組合")), ok: window.client.capabilityAvailable("desktop.profiles.create"), why: window.t(qsTr("目前無法建立組合")) }
            ]
            Text {
                text: window.t(qsTr("可以試試："))
                color: window.tokens.foregroundMuted
                font.pixelSize: window.tokens.fontSmall
            }
            Repeater {
                model: examples.visible ? examples.items : []
                Button {
                    required property var modelData
                    tokens: window.tokens
                    kind: "subtle"
                    enabled: modelData.ok
                    text: modelData.ok ? modelData.text : window.t(qsTr("%1（%2）")).arg(modelData.text).arg(modelData.why)
                    onClicked: {
                        window.conversation.draft = modelData.text;
                        window.conversation.send();
                    }
                }
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

            header: Button {
                visible: window.conversation.hasOlder
                height: visible ? implicitHeight : 0
                tokens: window.tokens
                kind: "subtle"
                text: window.t(qsTr("載入較早的訊息"))
                onClicked: window.conversation.loadOlder()
            }
            // The answer as it streams; the stored answer replaces it.
            footer: Rectangle {
                visible: window.conversation.streamText.length > 0 && window.conversation.turnActive
                width: Math.min(list.width * 0.85, streaming.implicitWidth + window.tokens.spaceWide * 2)
                height: visible ? streaming.implicitHeight + window.tokens.space * 2 : 0
                radius: window.tokens.radiusSmall
                color: window.tokens.surface
                border.color: window.tokens.border
                Text {
                    id: streaming
                    anchors.fill: parent
                    anchors.margins: window.tokens.space
                    width: list.width * 0.85 - window.tokens.spaceWide * 2
                    wrapMode: Text.Wrap
                    textFormat: Text.PlainText
                    text: window.conversation.streamText
                    color: window.tokens.foregroundMuted
                    font.pixelSize: window.tokens.fontBody
                    Accessible.role: Accessible.StaticText
                    Accessible.name: window.t(qsTr("Ditto 正在回答：")) + text
                }
            }

            delegate: Item {
                id: row
                required property var modelData
                width: list.width
                height: row.modelData.type === "tool/result" ? card.implicitHeight + undo.height + window.tokens.space * 2 : bubble.implicitHeight + window.tokens.space * 2
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
                // Undo is a new change through Core, offered on what committed.
                Button {
                    id: undo
                    anchors.top: card.bottom
                    visible: !!card.record && card.record.state === "committed" && !window.compact
                    height: visible ? implicitHeight : 0
                    tokens: window.tokens
                    kind: "subtle"
                    text: window.t(qsTr("撤銷這項變更"))
                    onClicked: window.conversation.undoChange(card.record.change_id)
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

            // Attached context: what will be sent with the next message.
            Flow {
                width: parent.width
                spacing: window.tokens.spaceTight
                visible: window.conversation.attached.length > 0
                Accessible.role: Accessible.List
                Accessible.name: window.t(qsTr("附加內容"))
                Repeater {
                    model: window.conversation.attached
                    Rectangle {
                        id: chip
                        required property var modelData
                        readonly property string kindText: modelData.kind === "file" ? window.t(qsTr("檔案"))
                            : modelData.kind === "clipboard" ? window.t(qsTr("剪貼簿")) : window.t(qsTr("螢幕畫面"))
                        height: window.tokens.controlHeight
                        width: chipLabel.implicitWidth + remove.width + window.tokens.space * 3
                        radius: height / 2
                        color: window.tokens.surface
                        border.color: window.tokens.border
                        Text {
                            id: chipLabel
                            anchors.left: parent.left
                            anchors.leftMargin: window.tokens.space
                            anchors.verticalCenter: parent.verticalCenter
                            text: (chip.modelData.kind === "clipboard" ? chip.kindText : window.t(qsTr("%1：%2")).arg(chip.kindText).arg(chip.modelData.label))
                                + "  " + Math.max(1, Math.round(chip.modelData.bytes / 1024)) + " KB"
                                + (chip.modelData.truncated ? window.t(qsTr("（已截斷）")) : "")
                            color: window.tokens.foreground
                            font.pixelSize: window.tokens.fontSmall
                        }
                        Button {
                            id: remove
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            tokens: window.tokens
                            kind: "subtle"
                            text: "✕"
                            accessibleName: window.t(qsTr("移除附加內容：%1")).arg(chip.kindText)
                            onClicked: window.conversation.detach(chip.modelData.context_id)
                        }
                    }
                }
            }
            Text {
                visible: text.length > 0
                width: parent.width
                maximumLineCount: 3
                elide: Text.ElideRight
                wrapMode: Text.Wrap
                textFormat: Text.PlainText
                text: {
                    const items = window.conversation.attached;
                    if (items.length === 0) {
                        return "";
                    }
                    const preview = window.conversation.previews[items[items.length - 1].context_id];
                    if (!preview) {
                        return "";
                    }
                    return preview.text !== null && preview.text !== undefined
                        ? window.t(qsTr("預覽：")) + preview.text
                        : window.t(qsTr("螢幕畫面 %1×%2，只在送出時傳給模型")).arg(preview.image_size[0]).arg(preview.image_size[1]);
                }
                color: window.tokens.foregroundMuted
                font.pixelSize: window.tokens.fontSmall
            }

            Row {
                spacing: window.tokens.spaceTight
                visible: window.conversation.connected && !window.compact
                Button {
                    tokens: window.tokens
                    kind: "subtle"
                    text: window.t(qsTr("附加檔案…"))
                    enabled: !window.conversation.attaching
                    onClicked: fileDialog.open()
                }
                Button {
                    tokens: window.tokens
                    kind: "subtle"
                    text: window.t(qsTr("附加剪貼簿"))
                    enabled: !window.conversation.attaching
                    onClicked: window.conversation.attach("clipboard")
                }
                Button {
                    tokens: window.tokens
                    kind: "subtle"
                    text: window.t(qsTr("附加螢幕畫面"))
                    enabled: !window.conversation.attaching
                    onClicked: window.conversation.attach("capture")
                }
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

    }

    /// Only the path the person chooses here is read, by Core, beneath their
    /// home directory.
    FileDialog {
        id: fileDialog
        title: window.t(qsTr("選擇要附加的文字檔"))
        nameFilters: [window.t(qsTr("文字檔 (*.txt *.md *.json *.csv *.log)")), window.t(qsTr("所有檔案 (*)"))]
        onAccepted: window.conversation.attach("file", decodeURIComponent(selectedFile.toString().replace("file://", "")))
    }
}
