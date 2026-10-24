import QtQuick
import "root:/sdk/Ditto/Ui"

/// Change history (G1-SHELL-08): every ChangeSet with what was asked, what
/// actually changed, the result class, where it came from and whether it
/// can still be undone. The four result classes are worded so a person can
/// tell what took effect: a partial result lists applied and not-restored
/// items; an unknown result says so, with no retry button; a change the crash
/// recovery settled says when. Undo is step by step, and Core refuses to undo
/// an older change that a newer one depends on.
Flickable {
    id: page

    required property var client
    required property var tokens
    property var config: ({})
    property string pageId: "history"
    property string entryId: ""
    readonly property Flickable flickable: page
    /// #116 application style (Profile `ui_style`, light recipe); false keeps the existing page.
    readonly property bool jelly: tokens.uiCandidate === true

    contentWidth: width
    contentHeight: column.implicitHeight + tokens.appPagePad * 2
    clip: true
    boundsBehavior: Flickable.StopAtBounds

    property var changes: []
    property var expanded: ({})       // change id → full ChangeRecord
    property string notice: ""
    property string diagnostic: ""
    property bool more: true
    /// Every change_updated and resync starts a new list generation: a list
    /// answer from an older one may undo what that update said, so the list
    /// is read again instead (#171). One list read is out at a time.
    property int listGeneration: 0
    property bool listing: false
    property bool listAgain: false

    ChangeText {
        id: words
        client: page.client
    }

    // Open records, read so that a late answer never undoes a newer one.
    ChangeReads {
        id: reads
        client: page.client
        onRead: function (changeId, record) {
            const table = Object.assign({}, page.expanded);
            table[changeId] = record;
            page.expanded = table;
        }
        onFailed: function (changeId, error) {
            page.fail(error);
            // A first open that failed holds nothing: the row stays closed
            // and opening it again retries.
            if (!page.expanded[changeId]) {
                reads.forget(changeId);
            }
        }
    }

    function t(source) {
        return client.t(source);
    }

    function fail(error) {
        notice = client.errorText(error);
        diagnostic = client.diagnosticText(error);
    }

    /// The list is replaced (not extended): a record whose row leaves it is
    /// released, its read forgotten and its open card dropped. The row comes
    /// back closed with a later page, and opening it reads it afresh.
    function replaceList(list) {
        changes = list;
        const listed = new Set(list.map(change => change.change_id));
        reads.retain(Array.from(listed));
        const table = Object.assign({}, expanded);
        let dropped = false;
        for (const changeId of Object.keys(table)) {
            if (!listed.has(changeId)) {
                delete table[changeId];
                dropped = true;
            }
        }
        if (dropped) {
            expanded = table;
        }
    }

    function reload() {
        if (listing) {
            listAgain = true;
            return;
        }
        listing = true;
        const generation = listGeneration;
        client.capability("desktop.changes.list", { limit: 30 }, function (result) {
            page.listing = false;
            if (generation === page.listGeneration) {
                page.replaceList(result.changes);
                page.more = result.changes.length === 30;
            } else {
                page.listAgain = true;
            }
            if (page.listAgain) {
                page.listAgain = false;
                page.reload();
            }
        }, function (error) {
            page.listing = false;
            // Only a failure of a current read is news; a read queued behind
            // this one still goes out.
            if (generation === page.listGeneration) {
                page.fail(error);
            }
            if (page.listAgain || generation !== page.listGeneration) {
                page.listAgain = false;
                page.reload();
            }
        });
    }

    function loadMore() {
        if (changes.length === 0) {
            return;
        }
        const generation = listGeneration;
        client.capability("desktop.changes.list", { limit: 30, before: changes[changes.length - 1].change_id }, function (result) {
            // Sent before a newer update: read the same page again.
            if (generation !== page.listGeneration) {
                page.loadMore();
                return;
            }
            page.changes = page.changes.concat(result.changes);
            page.more = result.changes.length === 30;
        }, fail);
    }

    function open(changeId) {
        if (expanded[changeId]) {
            reads.forget(changeId);
            const table = Object.assign({}, expanded);
            delete table[changeId];
            expanded = table;
            return;
        }
        reads.request(changeId);
    }

    function refresh(changeId) {
        reads.refresh(changeId);
    }

    function undo(record) {
        notice = "";
        diagnostic = "";
        client.undoChange(record.change_id, function (result) {
            page.notice = result.state === "committed" ? page.t(qsTr("已撤銷。撤銷本身也記錄成一筆變更。")) : words.outcomeSentence(result);
            page.reload();
        }, fail);
    }

    Component.onCompleted: reload()

    Connections {
        target: page.client
        // After a resync or a reconnect: changes made meanwhile are listed,
        // and open records are read again (a Profile may have been deleted).
        function onCapabilitiesReloaded() {
            page.listGeneration++;
            page.reload();
            // Open records, and those whose first read is still out.
            reads.refreshAll();
        }
        function onChangeUpdated(change) {
            page.listGeneration++;
            // Records the page holds first, listed or not, so that no
            // update for one is skipped.
            if (page.expanded[change.change_id]) {
                // The update is newer than the open record: it applies at
                // once (the record keeps its card and items).
                const table = Object.assign({}, page.expanded);
                table[change.change_id] = Object.assign({}, page.expanded[change.change_id], change);
                page.expanded = table;
            }
            // Open, or opening with its first read still out: read again,
            // and an answer to a read sent before this is not applied.
            if (reads.holds(change.change_id)) {
                page.refresh(change.change_id);
            }
            const index = page.changes.findIndex(item => item.change_id === change.change_id);
            if (index < 0) {
                // Older than the loaded rows (Core publishes a deleted
                // Profile's changes again): read with its page, not put on top.
                if (page.changes.length > 0 && change.change_id < page.changes[page.changes.length - 1].change_id) {
                    return;
                }
                page.changes = [change].concat(page.changes);
            } else {
                const list = page.changes.slice();
                list[index] = change;
                page.changes = list;
            }
        }
    }

    Column {
        id: column
        x: page.tokens.appPagePad
        y: page.tokens.appPagePad
        width: page.width - page.tokens.appPagePad * 2
        spacing: page.tokens.space

        Text {
            text: page.t(qsTr("變更紀錄"))
            color: page.tokens.appInk
            font.pixelSize: page.tokens.appFontHeading
            font.bold: true
            Accessible.role: Accessible.Heading
            Accessible.name: text
        }

        Text {
            width: parent.width
            wrapMode: Text.WordWrap
            text: page.t(qsTr("每一次改變桌面都記在這裡，包含沒有套用成功的。撤銷會一步一步往回，較新的變更要先撤銷。"))
            color: page.tokens.appInkMuted
            font.pixelSize: page.tokens.appFontCaption
        }

        Text {
            visible: page.notice.length > 0
            width: parent.width
            wrapMode: Text.WordWrap
            text: page.notice
            color: page.tokens.appWarning
            font.pixelSize: page.tokens.appFontBody
            Accessible.role: Accessible.AlertMessage
            Accessible.name: text
        }

        Diagnostics {
            width: parent.width
            tokens: page.tokens
            title: page.t(qsTr("診斷"))
            text: page.diagnostic
        }

        Repeater {
            model: page.changes

            Rectangle {
                id: changeRow
                required property var modelData
                readonly property var record: page.expanded[modelData.change_id] || null
                width: column.width
                height: changeColumn.implicitHeight + page.tokens.space * 2
                radius: page.tokens.appPlateRadius
                color: page.tokens.appPlate
                border.color: page.tokens.appPlateBorder
                border.width: 1

                Column {
                    id: changeColumn
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.margins: page.tokens.space
                    spacing: page.tokens.space

                    Item {
                        width: parent.width
                        height: summaryRow.implicitHeight
                        activeFocusOnTab: true
                        Accessible.role: Accessible.Button
                        Accessible.name: titleText.text + " " + stateBadge.text
                        Keys.onReturnPressed: page.open(changeRow.modelData.change_id)
                        Keys.onSpacePressed: page.open(changeRow.modelData.change_id)

                        Row {
                            id: summaryRow
                            spacing: page.tokens.space

                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                width: 120
                                text: words.dateTime(changeRow.modelData.created_at)
                                color: page.tokens.appInkMuted
                                font.pixelSize: page.tokens.appFontCaption
                            }
                            Badge {
                                id: stateBadge
                                anchors.verticalCenter: parent.verticalCenter
                                tokens: page.tokens
                                text: words.stateLabel(changeRow.modelData)
                                tone: words.tone(changeRow.modelData)
                            }
                            Text {
                                id: titleText
                                anchors.verticalCenter: parent.verticalCenter
                                text: page.client.key(changeRow.modelData.title_key, {})
                                color: page.tokens.appInk
                                font.pixelSize: page.tokens.appFontBody
                                font.bold: true
                            }
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: words.originLabel(changeRow.modelData.origin)
                                color: page.tokens.appInkMuted
                                font.pixelSize: page.tokens.appFontCaption
                            }
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: changeRow.record ? "▾" : "▸"
                                color: page.tokens.appInkMuted
                                font.pixelSize: page.tokens.appFontCaption
                            }
                        }

                        Rectangle {
                            anchors.fill: parent
                            anchors.margins: -3
                            color: "transparent"
                            border.color: page.tokens.focus
                            border.width: parent.activeFocus ? 2 : 0
                        }

                        MouseArea {
                            anchors.fill: parent
                            onClicked: page.open(changeRow.modelData.change_id)
                        }
                    }

                    ChangeCard {
                        visible: !!changeRow.record
                        width: parent.width
                        client: page.client
                        tokens: page.tokens
                        record: changeRow.record
                    }

                    Row {
                        visible: !!changeRow.record
                        spacing: page.tokens.space

                        // Undo exists only for a change that took effect and
                        // that Core can still undo (ChangeText.undoable). An
                        // unknown result has no retry here: what is true is
                        // read back first, then decided.
                        Button {
                            visible: words.undoable(changeRow.record)
                            tokens: page.tokens
                            text: page.t(qsTr("撤銷這次變更"))
                            onClicked: page.undo(changeRow.record)
                        }
                        Button {
                            visible: !!changeRow.record && words.pendingConfirmation(changeRow.record)
                            tokens: page.tokens
                            kind: "primary"
                            text: page.t(qsTr("保留"))
                            onClicked: page.client.confirmChange(changeRow.record.change_id, function () {
                                page.refresh(changeRow.record.change_id);
                            }, page.fail)
                        }
                        Button {
                            visible: !!changeRow.record && words.pendingConfirmation(changeRow.record)
                            tokens: page.tokens
                            text: page.t(qsTr("取消並回復"))
                            onClicked: page.client.cancelChange(changeRow.record.change_id, function () {
                                page.refresh(changeRow.record.change_id);
                            }, page.fail)
                        }
                    }
                }
            }
        }

        Button {
            visible: page.more && page.changes.length > 0
            tokens: page.tokens
            text: page.t(qsTr("載入較早的紀錄"))
            onClicked: page.loadMore()
        }

        Text {
            visible: page.changes.length === 0
            text: page.t(qsTr("還沒有任何變更。"))
            color: page.tokens.appInkMuted
            font.pixelSize: page.tokens.appFontBody
        }
    }
}
