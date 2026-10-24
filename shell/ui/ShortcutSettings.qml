pragma ComponentBehavior: Bound
import QtQuick
import "../change"

/// #190 UNSELECTED preview. Only UI drafts live here; Core owns bindings.
Column {
    id: root
    required property var client
    required property var tokens
    property bool externalBusy: false
    property var bindings: []
    property var info: []
    property var commands: []
    property string revision: ""
    property string profileId: ""
    property string bindingPath: ""
    property bool loaded: false
    property bool loading: false
    property bool writing: false
    property bool uncertain: false
    property var record: null
    property var expected: null
    property string draftRevision: ""
    property string draftProfile: ""
    property var draftBefore: []
    property int editing: -2 // -2 closed, -1 new, otherwise snapshot index
    property string draftChord: ""
    property string draftCommand: ""
    property string message: ""
    property string diagnostic: ""
    property var returnFocus: null
    readonly property bool pending: !!record && !!record.confirmation && record.confirmation.state === "pending"
    readonly property bool locked: externalBusy || writing || pending || uncertain
    readonly property bool canWrite: loaded && !loading && !locked
    readonly property string conflict: draftConflict()
    spacing: tokens.space
    objectName: "shortcutSettings"

    function t(source) { return client.t(source); }
    function title(commandId) {
        const command = commands.find(item => item.command_id === commandId);
        return command ? client.key(command.title_key, {}) : commandId;
    }
    function keyLabel(chord) {
        return chord.split("+").map(key => key === "Space" ? t(qsTr("空白鍵")) : key).join(" + ");
    }
    function draftConflict() {
        const chord = draftChord.trim();
        if (!chord) return "";
        const reserved = info.find(item => item.reserved && item.chord === chord);
        if (reserved) return t(qsTr("這組按鍵由系統保留：%1。請換一組。")).arg(title(reserved.command));
        const other = draftBefore.find((item, index) => index !== editing && item.chord === chord);
        return other ? t(qsTr("這組按鍵已用於「%1」。請換一組。")).arg(title(other.command)) : "";
    }
    function failed(error) {
        if (writing && (error.name === "timeout" || error.message === "disconnected" || error.data && error.data.outcome === "unknown")) uncertain = true;
        writing = false;
        loading = false;
        message = t(qsTr("尚未儲存。已保留輸入，請查看原因後再試。")) + " " + client.errorText(error);
        if (uncertain) message = t(qsTr("儲存結果未知。輸入已保留，請重新讀取狀態並查看變更紀錄，勿重複套用。"));
        diagnostic = client.diagnosticText(error);
    }
    function reload() {
        if (loading) return;
        loading = true;
        client.capability("desktop.profiles.get", { history_limit: 1 }, function(result) {
            root.bindings = result.document.shortcuts || [];
            root.revision = result.profile.head_revision || "";
            root.profileId = result.profile.profile_id;
            root.loaded = true;
            root.loading = false;
        }, failed);
        client.capability("desktop.shortcuts.list", {}, function(result) {
            root.info = result.shortcuts;
            root.bindingPath = result.binding_path || "";
        }, failed);
        client.capability("desktop.commands.list", {}, function(result) { root.commands = result.commands; }, failed);
    }
    function begin(index, control) {
        if (!canWrite || editing !== -2) return;
        draftBefore = bindings.slice();
        draftRevision = revision;
        draftProfile = profileId;
        editing = index;
        draftChord = index >= 0 ? bindings[index].chord : "";
        draftCommand = index >= 0 ? bindings[index].command : "";
        message = "";
        diagnostic = "";
        returnFocus = control || null;
    }
    function cancel() {
        if (locked) return;
        editing = -2;
        draftChord = "";
        draftCommand = "";
        message = "";
        if (returnFocus) returnFocus.forceActiveFocus();
    }
    function save() {
        if (!canWrite || editing === -2 || conflict || !draftChord.trim() || !draftCommand) return;
        const after = draftBefore.slice();
        const binding = { chord: draftChord.trim(), command: draftCommand };
        if (editing < 0) after.push(binding); else after[editing] = binding;
        submit(after);
    }
    function remove() {
        if (!canWrite || editing < 0) return;
        submit(draftBefore.filter((item, index) => index !== editing));
    }
    function submit(after) {
        expected = after;
        record = null;
        writing = true;
        message = t(qsTr("正在套用快捷鍵…輸入會保留到確認完成。"));
        client.propose([{ op: "set_value", path: "/shortcuts", before: draftBefore, after: after }],
            { surface: "personalization", baseRevision: draftRevision, profileId: draftProfile }, acceptRecord, failed);
    }
    function acceptRecord(change) {
        uncertain = false;
        record = change;
        client.notePending(change);
        if (pending) {
            writing = false;
            message = t(qsTr("請試用快捷鍵，再按「保留」。倒數結束會還原，輸入仍會保留。"));
            return;
        }
        if (change.state !== "committed" || !change.committed_revision
                || ["confirmed", "not_required"].indexOf((change.confirmation || {}).state) < 0
                || change.result !== "success") {
            writing = false;
            message = t(qsTr("這次變更未保留。輸入仍在，可修改後再試。"));
            reload();
            return;
        }
        writing = true;
        client.capability("desktop.profiles.get", { profile_id: draftProfile, history_limit: 1 }, function(result) {
            root.writing = false;
            if (result.profile.head_revision !== change.committed_revision
                    || root.client.profileId && root.client.profileId !== root.draftProfile
                    || JSON.stringify(result.document.shortcuts || []) !== JSON.stringify(root.expected)) {
                root.uncertain = true;
                root.message = root.t(qsTr("尚無法確認儲存結果。輸入已保留，請重新讀取狀態。"));
                return;
            }
            root.expected = null;
            root.editing = -2;
            root.draftChord = "";
            root.draftCommand = "";
            root.message = root.t(qsTr("快捷鍵已儲存。可在變更紀錄中撤銷。"));
            root.reload();
            addButton.forceActiveFocus();
        }, function(error) { root.uncertain = true; root.failed(error); });
    }
    function reconcile() {
        reload();
        if (record && expected) client.capability("desktop.changes.get", { change_id: record.change_id }, acceptRecord, failed);
    }
    Component.onCompleted: reload()
    Connections {
        target: root.client
        function onProfileChanged(payload) { root.reload(); }
        function onCapabilitiesReloaded() { root.reconcile(); }
        function onChangeUpdated(change) {
            if (root.record && root.expected && change.change_id === root.record.change_id) root.acceptRecord(change);
        }
    }

    Section {
        tokens: root.tokens
        title: root.t(qsTr("快捷鍵"))
        carded: false
        note: root.t(qsTr("先選用途，再設定按鍵。系統保留的快捷鍵無法更改。"))
        Text {
            width: parent.width
            wrapMode: Text.WordWrap
            text: root.t(qsTr("請輸入按鍵名稱，例如 Super+Space。這裡不會擷取全域按鍵；衝突仍由系統在套用前檢查。"))
            color: root.tokens.appInkMuted
            font.pixelSize: root.tokens.appFontCaption
        }
        Text {
            visible: root.bindingPath === "shell_keyboard_only"
            width: parent.width
            wrapMode: Text.WordWrap
            text: root.t(qsTr("目前僅在桌面介面有鍵盤焦點時可用，尚未綁定全域快捷鍵。"))
            color: root.tokens.appWarning
            font.pixelSize: root.tokens.appFontBody
        }
        Repeater {
            model: root.info
            Column {
                id: row
                required property var modelData
                readonly property int bindingIndex: root.bindings.findIndex(item => item.chord === modelData.chord && item.command === modelData.command)
                width: parent.width
                spacing: root.tokens.space
                Rectangle {
                    width: parent.width
                    height: rowContent.implicitHeight + root.tokens.space * 2
                    radius: root.tokens.radiusSmall
                    color: root.tokens.uiCandidate ? root.tokens.uiTonal : root.tokens.surface
                    Column {
                        id: rowContent
                        x: root.tokens.space; y: root.tokens.space
                        width: parent.width - root.tokens.space * 2
                        spacing: root.tokens.space / 2
                        Text {
                            width: parent.width
                            text: root.title(row.modelData.command)
                            wrapMode: Text.WordWrap
                            color: root.tokens.appInk
                            font.pixelSize: root.tokens.appFontBody
                            font.weight: Font.DemiBold
                        }
                        Flow {
                            width: parent.width
                            spacing: root.tokens.space
                            Text {
                                width: Math.min(implicitWidth, rowContent.width)
                                wrapMode: Text.WrapAnywhere
                                text: root.keyLabel(row.modelData.chord)
                                color: root.tokens.appInk
                                font.pixelSize: root.tokens.appFontBody
                                topPadding: 5
                            }
                            Badge {
                                tokens: root.tokens
                                text: row.modelData.reserved ? root.t(qsTr("系統保留"))
                                    : row.modelData.conflict ? root.t(qsTr("衝突"))
                                    : row.modelData.bound ? root.t(qsTr("已生效")) : root.t(qsTr("未生效"))
                                tone: row.modelData.conflict ? "bad" : row.modelData.bound ? "good" : "warn"
                            }
                            Button {
                                id: editButton
                                visible: !row.modelData.reserved && row.bindingIndex >= 0
                                tokens: root.tokens
                                text: root.t(qsTr("編輯"))
                                accessibleName: root.t(qsTr("編輯 %1")).arg(root.title(row.modelData.command))
                                kind: "subtle"
                                enabled: root.canWrite && root.editing === -2
                                onClicked: root.begin(row.bindingIndex, editButton)
                            }
                        }
                    }
                }
                // A: one active editor directly under its selected binding.
                Loader {
                    objectName: "shortcutInlineSlot"
                    width: parent.width
                    active: root.editing >= 0 && root.editing === row.bindingIndex
                    sourceComponent: editForm
                }
            }
        }
        Button {
            id: addButton
            objectName: "shortcutAdd"
            tokens: root.tokens
            text: root.t(qsTr("新增快捷鍵"))
            enabled: root.canWrite && root.editing === -2
            onClicked: root.begin(-1, addButton)
        }
        Loader {
            objectName: "shortcutNewSlot"
            width: parent.width
            active: root.editing === -1
            sourceComponent: editForm
        }
        Text {
            objectName: "shortcutMessage"
            visible: root.editing === -2 && text.length > 0
            width: parent.width
            wrapMode: Text.WordWrap
            text: root.message
            color: root.tokens.appWarning
            font.pixelSize: root.tokens.appFontBody
            Accessible.role: Accessible.AlertMessage
            Accessible.name: text
        }
        Diagnostics { width: parent.width; tokens: root.tokens; title: root.t(qsTr("診斷")); text: root.diagnostic }
        Button {
            visible: root.message.length > 0 && !root.pending
            tokens: root.tokens
            text: root.t(qsTr("重新讀取狀態"))
            enabled: !root.writing && !root.loading
            onClicked: root.reconcile()
        }
        ChangeCard { width: parent.width; visible: !!root.record; client: root.client; tokens: root.tokens; record: root.record }
    }
    Component {
        id: editForm
        Column {
            width: parent.width
            spacing: root.tokens.space
            Component.onCompleted: chordField.focusInput()
            Keys.onEscapePressed: event => { root.cancel(); event.accepted = true; }
            Text {
                width: parent.width
                wrapMode: Text.WordWrap
                text: root.editing < 0 ? root.t(qsTr("新增快捷鍵")) : root.t(qsTr("編輯 %1")).arg(root.title(root.draftBefore[root.editing].command))
                color: root.tokens.appInk
                font.pixelSize: root.tokens.appFontBody
                font.weight: Font.DemiBold
            }
            Text { text: root.t(qsTr("用途")); color: root.tokens.appInkMuted; font.pixelSize: root.tokens.appFontCaption }
            Choice {
                objectName: "shortcutCommand"
                tokens: root.tokens
                maxWidth: parent.width
                accessibleName: root.t(qsTr("用途"))
                enabled: !root.locked
                value: root.draftCommand
                options: root.commands.filter(command => command.command_id !== "session.lock" && command.command_id !== "rescue.open")
                    .map(command => ({ value: command.command_id, label: root.client.key(command.title_key, {}) }))
                onChosen: value => root.draftCommand = value
            }
            Text { text: root.t(qsTr("按鍵組合")); color: root.tokens.appInkMuted; font.pixelSize: root.tokens.appFontCaption }
            TextField {
                id: chordField
                objectName: "shortcutChord"
                width: parent.width
                tokens: root.tokens
                placeholder: root.t(qsTr("例如 Super+Space"))
                accessibleName: root.t(qsTr("按鍵組合"))
                enabled: !root.locked
                text: root.draftChord
                onTextChanged: root.draftChord = text
                onAccepted: root.save()
            }
            Text {
                objectName: "shortcutConflict"
                visible: text.length > 0
                width: parent.width
                wrapMode: Text.WordWrap
                text: root.conflict
                color: root.tokens.appWarning
                font.pixelSize: root.tokens.appFontBody
                Accessible.role: Accessible.AlertMessage
                Accessible.name: text
            }
            Text {
                visible: text.length > 0
                width: parent.width
                wrapMode: Text.WordWrap
                text: root.message
                color: root.tokens.appWarning
                font.pixelSize: root.tokens.appFontBody
                Accessible.role: Accessible.AlertMessage
                Accessible.name: text
            }
            Flow {
                width: parent.width
                spacing: root.tokens.space
                Button {
                    objectName: "shortcutSave"
                    tokens: root.tokens
                    text: root.t(qsTr("套用並試用"))
                    kind: "primary"
                    enabled: root.canWrite && !root.conflict && root.draftChord.trim().length > 0 && root.draftCommand.length > 0
                    onClicked: root.save()
                }
                Button { objectName: "shortcutCancel"; tokens: root.tokens; text: root.t(qsTr("取消")); enabled: !root.locked; onClicked: root.cancel() }
                Button { visible: root.editing >= 0; tokens: root.tokens; text: root.t(qsTr("移除")); kind: "subtle"; enabled: root.canWrite; onClicked: root.remove() }
            }
        }
    }
}
