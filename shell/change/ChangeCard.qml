import QtQuick
import "../ui"

/// The change card (the prototype's interaction contract): kind, title, each
/// item as before → after, and a footnote. Everything comes from Core — the
/// card of a ChangeRecord, or the items of a `profiles.diff` — rendered from
/// translation keys in the current language. The Shell computes no diff.
///
/// With a `record`, the card also shows the real state of that ChangeSet and,
/// for partial and unknown results, what took effect and what did not.
Column {
    id: card

    required property var client
    required property var tokens
    /// A ChangeRecord (full) or null.
    property var record: null
    /// A ChangeCard ({kind, title_key, title_args, items, footnote_key}); taken
    /// from `record.card` when a record is given.
    property var cardData: record ? record.card : null
    /// Plain diff items (profiles.diff) when there is no card.
    property var items: cardData ? cardData.items : []
    property string title: cardData ? client.key(cardData.title_key, cardData.title_args || {}) : ""
    property string kind: cardData ? cardData.kind : "diff"
    property bool showDiagnostics: true

    spacing: tokens.space

    ChangeText {
        id: words
        client: card.client
    }

    Row {
        spacing: card.tokens.space
        width: card.width

        Text {
            text: words.kindLabel(card.kind) + "  ·  " + card.client.t(qsTr("%1 項變更")).arg(card.items.length)
            color: card.tokens.foregroundMuted
            font.pixelSize: card.tokens.fontSmall
            anchors.verticalCenter: parent.verticalCenter
        }

        Badge {
            visible: !!card.record
            tokens: card.tokens
            text: words.stateLabel(card.record)
            tone: words.tone(card.record)
            anchors.verticalCenter: parent.verticalCenter
        }
    }

    Text {
        visible: text.length > 0
        width: card.width
        wrapMode: Text.WordWrap
        text: card.title
        color: card.tokens.foreground
        font.pixelSize: card.tokens.fontTitle
        font.bold: true
        Accessible.role: Accessible.Heading
        Accessible.name: text
    }

    Text {
        visible: !!card.record && text.length > 0
        width: card.width
        wrapMode: Text.WordWrap
        text: words.outcomeSentence(card.record)
        color: card.tokens.foreground
        font.pixelSize: card.tokens.fontBody
    }

    Text {
        visible: card.items.length === 0 && !card.record
        text: card.client.t(qsTr("兩者沒有差異。"))
        color: card.tokens.foregroundMuted
        font.pixelSize: card.tokens.fontBody
    }

    Repeater {
        model: card.items

        Rectangle {
            required property var modelData
            width: card.width
            height: row.implicitHeight + card.tokens.space * 2
            radius: card.tokens.radiusSmall
            color: card.tokens.surface
            border.color: card.tokens.border
            border.width: 1
            Accessible.role: Accessible.ListItem
            Accessible.name: label.text + ": " + before.text + " → " + after.text

            Row {
                id: row
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.margins: card.tokens.space
                spacing: card.tokens.space

                Text {
                    id: label
                    width: parent.width * 0.42
                    wrapMode: Text.WordWrap
                    text: card.client.key(modelData.label_key, modelData.label_args || {})
                    color: card.tokens.foreground
                    font.pixelSize: card.tokens.fontBody
                }

                Rectangle {
                    visible: words.isColor(modelData.before)
                    width: 12
                    height: 12
                    radius: 6
                    anchors.verticalCenter: parent.verticalCenter
                    color: visible ? modelData.before : "transparent"
                }

                Text {
                    id: before
                    text: words.valueText(modelData, "before")
                    color: card.tokens.foregroundMuted
                    font.pixelSize: card.tokens.fontBody
                    font.strikeout: modelData.kind !== "added"
                }

                Text {
                    text: "→"
                    color: card.tokens.foregroundMuted
                    font.pixelSize: card.tokens.fontBody
                }

                Rectangle {
                    visible: words.isColor(modelData.after)
                    width: 12
                    height: 12
                    radius: 6
                    anchors.verticalCenter: parent.verticalCenter
                    color: visible ? modelData.after : "transparent"
                }

                Text {
                    id: after
                    text: words.valueText(modelData, "after")
                    color: card.tokens.foreground
                    font.pixelSize: card.tokens.fontBody
                    font.bold: true
                }
            }
        }
    }

    /// Partial and unknown results list every item: what took effect, what
    /// was restored, what was not, and why.
    Column {
        visible: !!card.record && (card.record.state === "partially_applied" || card.record.state === "unknown"
            || card.record.state === "rolled_back" || card.record.state === "aborted" || card.record.result === "scheduled"
            || card.record.result === "partial")
            && (card.record.items || []).length > 0
        width: card.width
        spacing: 2

        Text {
            text: card.client.t(qsTr("逐項結果"))
            color: card.tokens.foreground
            font.pixelSize: card.tokens.fontBody
            font.bold: true
        }

        Repeater {
            model: card.record ? (card.record.items || []) : []

            Text {
                required property var modelData
                width: card.width
                wrapMode: Text.WordWrap
                text: "• " + card.client.t(qsTr("%1（%2）：%3")).arg(words.itemKeyName(modelData.key))
                    .arg(words.participantName(modelData.participant)).arg(words.itemStatusLabel(modelData.status))
                    + (modelData.reason ? card.client.t(qsTr("，原因：%1")).arg(words.reasonText(modelData.reason)) : "")
                color: modelData.status === "not_restored" || modelData.status === "failed" ? card.tokens.warning : card.tokens.foreground
                font.pixelSize: card.tokens.fontSmall
            }
        }
    }

    Text {
        visible: !!card.record && !!card.record.recovered_at
        width: card.width
        wrapMode: Text.WordWrap
        text: card.record && card.record.recovered_at
            ? card.client.t(qsTr("上次中斷，已於 %1 處理")).arg(words.time(card.record.recovered_at)) : ""
        color: card.tokens.warning
        font.pixelSize: card.tokens.fontBody
    }

    Text {
        visible: !!card.record && !!card.record.failure_key
        width: card.width
        wrapMode: Text.WordWrap
        text: card.record && card.record.failure_key ? card.client.key(card.record.failure_key, {}) : ""
        color: card.tokens.foregroundMuted
        font.pixelSize: card.tokens.fontSmall
    }

    Repeater {
        model: card.record && card.record.reasons ? card.record.reasons : []

        Text {
            required property var modelData
            width: card.width
            wrapMode: Text.WordWrap
            text: "• " + card.client.key(modelData.detail_key, modelData.detail || {})
            color: card.tokens.warning
            font.pixelSize: card.tokens.fontBody
        }
    }

    Text {
        visible: !!card.cardData && !!card.cardData.footnote_key
        width: card.width
        wrapMode: Text.WordWrap
        text: card.cardData && card.cardData.footnote_key ? card.client.key(card.cardData.footnote_key, {}) : ""
        color: card.tokens.foregroundMuted
        font.pixelSize: card.tokens.fontSmall
    }

    Diagnostics {
        visible: card.showDiagnostics && !!card.record
        width: card.width
        tokens: card.tokens
        title: card.client.t(qsTr("診斷"))
        text: card.record ? JSON.stringify({
            change_id: card.record.change_id,
            state: card.record.state,
            result: card.record.result,
            base_revision: card.record.base_revision,
            committed_revision: card.record.committed_revision,
            hot_swap_level: card.record.hot_swap_level,
            failure_key: card.record.failure_key,
            origin: card.record.origin,
            ops: card.record.ops,
            items: card.record.items,
            reasons: card.record.reasons,
            operations: card.record.operations
        }, null, 2) : ""
    }
}
