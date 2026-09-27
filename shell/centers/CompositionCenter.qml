import QtQuick
import Quickshell
import "../ui"
import "../change"

/// Composition center (G1-SHELL-06): what the desktop is made of, the saved
/// compositions, their versions and differences, try-it and apply, import
/// and export. Every change of content is a ChangeSet based on the head this
/// page read; naming and deleting a composition change no content and use
/// the profile capabilities directly.
Flickable {
    id: page

    required property var client
    required property var tokens

    contentWidth: width
    contentHeight: column.implicitHeight + tokens.spaceSection * 2
    clip: true
    boundsBehavior: Flickable.StopAtBounds

    // ---- state read from Core ---------------------------------------------------------
    property var profiles: []
    property var active: null          // profiles.get of the active profile
    property var selected: null        // profiles.get of the profile whose versions are shown
    property var packages: []
    property var manifests: ({})       // package id → manifest (newest version)
    property var layout: null
    property string notice: ""
    property string diagnostic: ""
    property var lastRecord: null
    property var diffResult: null
    property string diffFrom: ""
    property string diffTo: ""
    property var importCheck: null
    property string exportText: ""
    property bool busy: false

    readonly property var slotOrder: ["ui.panel_top", "ui.dock", "ui.launcher", "ui.tasks_panel", "ui.notifications", "layout.strategy"]

    ChangeText {
        id: words
        client: page.client
    }

    function t(source) {
        return client.t(source);
    }

    function fail(error) {
        busy = false;
        notice = client.errorText(error);
        diagnostic = client.diagnosticText(error);
    }

    function reload() {
        client.capability("desktop.profiles.list", {}, function (result) {
            page.profiles = result.profiles;
        }, fail);
        client.capability("desktop.profiles.get", { history_limit: 30 }, function (result) {
            page.active = result;
            if (!page.selected || page.selected.profile.profile_id === result.profile.profile_id) {
                page.selected = result;
            }
        }, fail);
        client.capability("desktop.plugins.list", {}, function (result) {
            page.packages = result.packages;
            for (const summary of result.packages) {
                if (summary.host_kind !== "qml" && summary.host_kind !== "core_builtin") {
                    continue;
                }
                client.capability("desktop.plugins.get", { package_id: summary.package_id }, function (detail) {
                    const table = Object.assign({}, page.manifests);
                    table[detail.manifest.id] = detail.manifest;
                    page.manifests = table;
                });
            }
        }, fail);
        client.capability("desktop.layout.get", {}, function (result) {
            page.layout = result;
        });
    }

    function selectProfile(profileId) {
        client.capability("desktop.profiles.get", { profile_id: profileId, history_limit: 30 }, function (result) {
            page.selected = result;
            page.diffFrom = "";
            page.diffTo = "";
            page.diffResult = null;
        }, fail);
    }

    Component.onCompleted: reload()

    Connections {
        target: page.client
        function onProfileChanged(payload) {
            page.reload();
        }
        function onChangeUpdated(change) {
            if (page.lastRecord && change.change_id === page.lastRecord.change_id) {
                client.capability("desktop.changes.get", { change_id: change.change_id }, function (record) {
                    page.lastRecord = record;
                });
            }
        }
    }

    // ---- composition of the active profile ------------------------------------------------
    function entryOf(document, entryId) {
        return document ? document.entries.find(entry => entry.entry_id === entryId) || null : null;
    }

    function boundPackage(slot) {
        if (!active) {
            return "";
        }
        const entry = entryOf(active.document, active.document.slots[slot]);
        return entry ? entry.package : "";
    }

    /// Packages that can fill a slot: installed, and declaring that slot.
    function candidates(slot) {
        const seen = {};
        const list = [];
        for (const summary of packages) {
            const manifest = manifests[summary.package_id];
            if (!manifest || !manifest.slots || manifest.slots.indexOf(slot) < 0 || seen[summary.package_id]) {
                continue;
            }
            seen[summary.package_id] = true;
            list.push({ value: summary.package_id, label: client.tr.packageName(summary.package_id), version: summary.version, host: summary.host_kind });
        }
        return list.sort((left, right) => left.label.localeCompare(right.label));
    }

    /// The ops of "put <package> in <slot>". An entry of that package already
    /// in the composition is re-bound, so its settings (a dock's pinned
    /// applications, say) come back with it; otherwise a new entry is added.
    /// The replaced entry stays in the composition, unbound, with its config.
    function swapOps(slot, packageId) {
        const document = active.document;
        const current = document.slots[slot] || null;
        const existing = document.entries.find(entry => entry.package === packageId && entry.entry_id !== current && !entry.disabled
            && Object.values(document.slots).indexOf(entry.entry_id) < 0);
        if (existing) {
            return [{ op: "bind_slot", slot: slot, from: current, to: existing.entry_id }];
        }
        const summary = packages.find(item => item.package_id === packageId);
        return [{
            op: "add_entry",
            slot: slot,
            entry: { package: packageId, version: summary ? summary.version : "1.0.0", host: summary ? summary.host_kind : "qml", config: {}, disabled: false }
        }];
    }

    function propose(ops, mode) {
        busy = true;
        notice = mode === "preview" ? t(qsTr("正在準備試看…")) : t(qsTr("正在套用…"));
        diagnostic = "";
        client.propose(ops, { mode: mode, surface: "composition_center" }, function (record) {
            page.busy = false;
            page.lastRecord = record;
            page.notice = "";
            client.notePending(record);
            page.reload();
        }, function (error) {
            page.fail(error);
            if (error.data && error.data.change_id) {
                client.capability("desktop.changes.get", { change_id: error.data.change_id }, function (record) {
                    page.lastRecord = record;
                });
            }
        });
    }

    // ---- profiles ---------------------------------------------------------------------------
    function createProfile(name, template) {
        if (name.trim().length === 0) {
            notice = t(qsTr("請先輸入名稱"));
            return;
        }
        client.capability("desktop.profiles.create", { name: name.trim(), from: template, idempotency_key: client.newKey("gui") }, function () {
            page.notice = t(qsTr("已建立「%1」")).arg(name.trim());
            page.reload();
        }, fail);
    }

    function duplicateProfile(profileId, name) {
        if (name.trim().length === 0) {
            notice = t(qsTr("請先輸入名稱"));
            return;
        }
        client.capability("desktop.profiles.duplicate", { profile_id: profileId, name: name.trim(), idempotency_key: client.newKey("gui") }, function () {
            page.notice = t(qsTr("已複製為「%1」")).arg(name.trim());
            page.reload();
        }, fail);
    }

    function renameProfile(profileId, name) {
        if (name.trim().length === 0) {
            notice = t(qsTr("請先輸入名稱"));
            return;
        }
        client.capability("desktop.profiles.rename", { profile_id: profileId, name: name.trim() }, function () {
            page.notice = t(qsTr("已重新命名為「%1」")).arg(name.trim());
            page.reload();
        }, fail);
    }

    function deleteProfile(profile) {
        client.capability("desktop.profiles.delete", { profile_id: profile.profile_id }, function () {
            page.notice = t(qsTr("已刪除「%1」")).arg(profile.name);
            if (page.selected && page.selected.profile.profile_id === profile.profile_id) {
                page.selected = page.active;
            }
            page.reload();
        }, fail);
    }

    function diff(fromRevision, toRevision) {
        client.capability("desktop.profiles.diff", { from: { revision_id: fromRevision }, to: { revision_id: toRevision } }, function (result) {
            page.diffResult = result;
        }, fail);
    }

    function diffProfiles(fromProfile, toProfile) {
        client.capability("desktop.profiles.diff", { from: { profile_id: fromProfile }, to: { profile_id: toProfile } }, function (result) {
            page.diffResult = result;
            page.diffFrom = "";
            page.diffTo = "";
        }, fail);
    }

    function exportProfile(profileId) {
        client.capability("desktop.profiles.export", { profile_id: profileId }, function (result) {
            page.exportText = JSON.stringify(result.export, null, 2);
        }, fail);
    }

    function parseImport() {
        try {
            return JSON.parse(importArea.text);
        } catch (error) {
            notice = t(qsTr("匯入內容不是有效的組合檔"));
            return null;
        }
    }

    function validateImport() {
        const value = parseImport();
        if (!value) {
            importCheck = null;
            return;
        }
        client.capability("desktop.profiles.import_validate", { export: value }, function (result) {
            page.importCheck = result;
        }, fail);
    }

    function runImport(name) {
        const value = parseImport();
        if (!value || !importCheck || !importCheck.importable) {
            return;
        }
        client.capability("desktop.profiles.import", { export: value, name: name.trim().length > 0 ? name.trim() : (value.profile_name || t(qsTr("匯入的組合"))), idempotency_key: client.newKey("gui") }, function () {
            page.notice = t(qsTr("已匯入。匯入的組合不會自動套用，可以在清單中試看或使用。"));
            page.importCheck = null;
            importArea.text = "";
            page.reload();
        }, fail);
    }

    Column {
        id: column
        x: page.tokens.spaceSection
        y: page.tokens.spaceSection
        width: page.width - page.tokens.spaceSection * 2
        spacing: page.tokens.spaceSection

        Text {
            text: page.t(qsTr("組合中心"))
            color: page.tokens.foreground
            font.pixelSize: page.tokens.fontHeading
            font.bold: true
            Accessible.role: Accessible.Heading
            Accessible.name: text
        }

        Text {
            visible: page.notice.length > 0
            width: parent.width
            wrapMode: Text.WordWrap
            text: page.notice
            color: page.tokens.warning
            font.pixelSize: page.tokens.fontBody
            Accessible.role: Accessible.AlertMessage
            Accessible.name: text
        }

        Diagnostics {
            width: parent.width
            tokens: page.tokens
            title: page.t(qsTr("診斷"))
            text: page.diagnostic
        }

        ChangeCard {
            visible: !!page.lastRecord
            width: parent.width
            client: page.client
            tokens: page.tokens
            record: page.lastRecord
        }

        // ---- what the active composition is made of --------------------------------
        Section {
            tokens: page.tokens
            title: page.active ? page.t(qsTr("目前使用：%1")).arg(page.active.profile.name) : page.t(qsTr("目前使用的組合"))
            note: page.t(qsTr("選擇一個元件後可以先「試看」（倒數後自動回復，按保留才留下）或直接「套用」。原本元件的設定會保留，換回來時一起恢復。"))

            Repeater {
                model: page.slotOrder

                Column {
                    id: slotRow
                    required property var modelData
                    readonly property string slot: modelData
                    readonly property string current: page.boundPackage(slot)
                    readonly property var options: slot === "layout.strategy" && page.layout
                        ? page.layout.available.map(item => ({ value: item.package, label: page.client.key(item.name_key, {}), host: "core_builtin" }))
                        : page.candidates(slot)
                    property string chosen: ""
                    width: parent.width
                    spacing: page.tokens.spaceTight

                    Row {
                        spacing: page.tokens.space
                        Text {
                            width: 150
                            anchors.verticalCenter: parent.verticalCenter
                            text: page.client.tr.slotName(slotRow.slot)
                            color: page.tokens.foreground
                            font.pixelSize: page.tokens.fontBody
                            font.bold: true
                        }
                        Choice {
                            tokens: page.tokens
                            maxWidth: slotRow.width - 158
                            options: slotRow.options
                            value: slotRow.chosen.length > 0 ? slotRow.chosen : slotRow.current
                            accessibleName: page.client.tr.slotName(slotRow.slot)
                            enabled: !page.busy && slotRow.options.length > 1
                            onChosen: value => slotRow.chosen = value === slotRow.current ? "" : value
                        }
                        Text {
                            visible: slotRow.options.length === 0
                            anchors.verticalCenter: parent.verticalCenter
                            text: slotRow.current.length > 0 ? page.client.tr.packageName(slotRow.current) : page.t(qsTr("（未設定）"))
                            color: page.tokens.foregroundMuted
                            font.pixelSize: page.tokens.fontBody
                        }
                    }

                    Row {
                        visible: slotRow.chosen.length > 0
                        spacing: page.tokens.space
                        leftPadding: 158

                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: page.t(qsTr("把「%1」換成「%2」")).arg(page.client.tr.packageName(slotRow.current)).arg(page.client.tr.packageName(slotRow.chosen))
                            color: page.tokens.foreground
                            font.pixelSize: page.tokens.fontBody
                        }
                        Button {
                            tokens: page.tokens
                            text: page.t(qsTr("試看"))
                            enabled: !page.busy
                            onClicked: {
                                page.propose(page.swapOps(slotRow.slot, slotRow.chosen), "preview");
                                slotRow.chosen = "";
                            }
                        }
                        Button {
                            tokens: page.tokens
                            kind: "primary"
                            text: page.t(qsTr("套用"))
                            enabled: !page.busy
                            onClicked: {
                                page.propose(page.swapOps(slotRow.slot, slotRow.chosen), "apply");
                                slotRow.chosen = "";
                            }
                        }
                        Button {
                            tokens: page.tokens
                            kind: "subtle"
                            text: page.t(qsTr("取消"))
                            onClicked: slotRow.chosen = ""
                        }
                    }
                }
            }
        }

        // ---- saved compositions --------------------------------------------------------
        Section {
            tokens: page.tokens
            title: page.t(qsTr("已存的組合"))

            Repeater {
                model: page.profiles

                Rectangle {
                    id: profileRow
                    required property var modelData
                    property string mode: ""     // "" | rename | duplicate | confirmDelete
                    width: parent.width
                    height: profileColumn.implicitHeight + page.tokens.space * 2
                    radius: page.tokens.radiusSmall
                    color: page.selected && page.selected.profile.profile_id === modelData.profile_id ? page.tokens.surfaceStrong : page.tokens.surface
                    border.color: page.tokens.border
                    border.width: 1

                    Column {
                        id: profileColumn
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.margins: page.tokens.space
                        spacing: page.tokens.spaceTight

                        Row {
                            spacing: page.tokens.space
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: profileRow.modelData.name
                                color: page.tokens.foreground
                                font.pixelSize: page.tokens.fontBody
                                font.bold: true
                            }
                            Badge {
                                visible: profileRow.modelData.active
                                anchors.verticalCenter: parent.verticalCenter
                                tokens: page.tokens
                                tone: "good"
                                text: page.t(qsTr("使用中"))
                            }
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: page.t(qsTr("最後修改 %1")).arg(words.dateTime(profileRow.modelData.updated_at))
                                color: page.tokens.foregroundMuted
                                font.pixelSize: page.tokens.fontSmall
                            }
                        }

                        Flow {
                            width: parent.width
                            spacing: page.tokens.space
                            Button {
                                visible: !profileRow.modelData.active
                                tokens: page.tokens
                                text: page.t(qsTr("試看"))
                                enabled: !page.busy
                                onClicked: page.propose([{ op: "switch_profile", to_profile: profileRow.modelData.profile_id }], "preview")
                            }
                            Button {
                                visible: !profileRow.modelData.active
                                tokens: page.tokens
                                kind: "primary"
                                text: page.t(qsTr("使用這個組合"))
                                enabled: !page.busy
                                onClicked: page.propose([{ op: "switch_profile", to_profile: profileRow.modelData.profile_id }], "apply")
                            }
                            Button {
                                tokens: page.tokens
                                text: page.t(qsTr("版本與差異"))
                                onClicked: page.selectProfile(profileRow.modelData.profile_id)
                            }
                            Button {
                                visible: !!page.active && !profileRow.modelData.active
                                tokens: page.tokens
                                text: page.t(qsTr("與目前使用的比較"))
                                onClicked: page.diffProfiles(page.active.profile.profile_id, profileRow.modelData.profile_id)
                            }
                            Button {
                                tokens: page.tokens
                                text: page.t(qsTr("複製"))
                                onClicked: profileRow.mode = "duplicate"
                            }
                            Button {
                                tokens: page.tokens
                                text: page.t(qsTr("重新命名"))
                                onClicked: profileRow.mode = "rename"
                            }
                            Button {
                                tokens: page.tokens
                                text: page.t(qsTr("匯出"))
                                onClicked: page.exportProfile(profileRow.modelData.profile_id)
                            }
                            Button {
                                tokens: page.tokens
                                kind: "subtle"
                                text: page.t(qsTr("刪除"))
                                // Core refuses to delete the composition in use; the
                                // button says why instead of failing.
                                enabled: !profileRow.modelData.active
                                accessibleName: profileRow.modelData.active ? page.t(qsTr("使用中的組合不能刪除")) : text
                                onClicked: profileRow.mode = "confirmDelete"
                            }
                        }

                        Text {
                            visible: profileRow.modelData.active
                            text: page.t(qsTr("使用中的組合不能刪除；先切換到另一個組合。"))
                            color: page.tokens.foregroundMuted
                            font.pixelSize: page.tokens.fontSmall
                        }

                        Row {
                            visible: profileRow.mode === "rename" || profileRow.mode === "duplicate"
                            spacing: page.tokens.space
                            TextField {
                                id: nameField
                                tokens: page.tokens
                                placeholder: profileRow.mode === "rename" ? page.t(qsTr("新的名稱")) : page.t(qsTr("複本的名稱"))
                                onAccepted: confirmName.clicked()
                            }
                            Button {
                                id: confirmName
                                tokens: page.tokens
                                kind: "primary"
                                text: profileRow.mode === "rename" ? page.t(qsTr("重新命名")) : page.t(qsTr("複製"))
                                onClicked: {
                                    if (profileRow.mode === "rename") {
                                        page.renameProfile(profileRow.modelData.profile_id, nameField.text);
                                    } else {
                                        page.duplicateProfile(profileRow.modelData.profile_id, nameField.text);
                                    }
                                    profileRow.mode = "";
                                    nameField.text = "";
                                }
                            }
                            Button {
                                tokens: page.tokens
                                kind: "subtle"
                                text: page.t(qsTr("取消"))
                                onClicked: profileRow.mode = ""
                            }
                        }

                        Row {
                            visible: profileRow.mode === "confirmDelete"
                            spacing: page.tokens.space
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: page.t(qsTr("刪除「%1」？它的版本紀錄也會一起刪除。")).arg(profileRow.modelData.name)
                                color: page.tokens.warning
                                font.pixelSize: page.tokens.fontBody
                            }
                            Button {
                                tokens: page.tokens
                                kind: "danger"
                                text: page.t(qsTr("刪除"))
                                onClicked: {
                                    page.deleteProfile(profileRow.modelData);
                                    profileRow.mode = "";
                                }
                            }
                            Button {
                                tokens: page.tokens
                                kind: "subtle"
                                text: page.t(qsTr("取消"))
                                onClicked: profileRow.mode = ""
                            }
                        }
                    }
                }
            }

            Row {
                spacing: page.tokens.space
                TextField {
                    id: newName
                    tokens: page.tokens
                    placeholder: page.t(qsTr("新組合的名稱"))
                }
                Choice {
                    id: template
                    tokens: page.tokens
                    property string chosenTemplate: "default"
                    value: chosenTemplate
                    options: [{ value: "default", label: page.t(qsTr("從預設開始")) }, { value: "empty", label: page.t(qsTr("空白")) }]
                    onChosen: value => chosenTemplate = value
                }
                Button {
                    tokens: page.tokens
                    kind: "primary"
                    text: page.t(qsTr("建立新組合"))
                    onClicked: {
                        page.createProfile(newName.text, template.chosenTemplate);
                        newName.text = "";
                    }
                }
            }
        }

        // ---- versions and differences -----------------------------------------------------
        Section {
            tokens: page.tokens
            title: page.selected ? page.t(qsTr("「%1」的版本")).arg(page.selected.profile.name) : page.t(qsTr("版本紀錄"))
            note: page.t(qsTr("選兩個版本（起點、終點）比較差異。每個版本都標示它是怎麼來的。"))

            Repeater {
                model: page.selected ? page.selected.history : []

                Rectangle {
                    id: revisionRow
                    required property var modelData
                    required property int index
                    width: parent.width
                    height: revisionLine.implicitHeight + page.tokens.space
                    radius: page.tokens.radiusSmall
                    color: page.diffFrom === modelData.revision_id || page.diffTo === modelData.revision_id ? page.tokens.surfaceStrong : "transparent"

                    Row {
                        id: revisionLine
                        anchors.verticalCenter: parent.verticalCenter
                        x: page.tokens.space
                        spacing: page.tokens.space

                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            width: 130
                            text: words.dateTime(revisionRow.modelData.created_at)
                            color: page.tokens.foreground
                            font.pixelSize: page.tokens.fontSmall
                        }
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            width: 110
                            text: words.revisionOrigin(revisionRow.modelData.origin)
                            color: page.tokens.foreground
                            font.pixelSize: page.tokens.fontSmall
                        }
                        Badge {
                            visible: revisionRow.index === 0
                            anchors.verticalCenter: parent.verticalCenter
                            tokens: page.tokens
                            tone: "info"
                            text: page.t(qsTr("目前版本"))
                        }
                        Badge {
                            visible: revisionRow.modelData.last_known_good === true
                            anchors.verticalCenter: parent.verticalCenter
                            tokens: page.tokens
                            tone: "good"
                            text: page.t(qsTr("最近可用"))
                        }
                        Badge {
                            visible: revisionRow.modelData.pending_confirmation === true
                            anchors.verticalCenter: parent.verticalCenter
                            tokens: page.tokens
                            tone: "warn"
                            text: page.t(qsTr("等待保留"))
                        }
                        Button {
                            tokens: page.tokens
                            kind: "subtle"
                            text: page.diffFrom === revisionRow.modelData.revision_id ? page.t(qsTr("起點 ✓")) : page.t(qsTr("設為起點"))
                            onClicked: page.diffFrom = revisionRow.modelData.revision_id
                        }
                        Button {
                            tokens: page.tokens
                            kind: "subtle"
                            text: page.diffTo === revisionRow.modelData.revision_id ? page.t(qsTr("終點 ✓")) : page.t(qsTr("設為終點"))
                            onClicked: page.diffTo = revisionRow.modelData.revision_id
                        }
                    }
                }
            }

            Button {
                tokens: page.tokens
                kind: "primary"
                text: page.t(qsTr("比較"))
                enabled: page.diffFrom.length > 0 && page.diffTo.length > 0 && page.diffFrom !== page.diffTo
                onClicked: page.diff(page.diffFrom, page.diffTo)
            }

            ChangeCard {
                visible: !!page.diffResult
                width: parent.width
                client: page.client
                tokens: page.tokens
                cardData: null
                kind: "diff"
                title: page.t(qsTr("差異"))
                items: page.diffResult ? page.diffResult.items : []
            }
        }

        // ---- import and export ------------------------------------------------------------
        Section {
            tokens: page.tokens
            title: page.t(qsTr("匯入與匯出"))
            note: page.t(qsTr("匯出的內容不含檔案路徑與密鑰。匯入前會先檢查，檢查結果顯示在這裡，不會立即套用。"))

            Column {
                visible: page.exportText.length > 0
                width: parent.width
                spacing: page.tokens.space
                TextArea {
                    width: parent.width
                    height: 160
                    tokens: page.tokens
                    readOnly: true
                    text: page.exportText
                    accessibleName: page.t(qsTr("匯出的組合"))
                }
                Row {
                    spacing: page.tokens.space
                    Button {
                        tokens: page.tokens
                        text: page.t(qsTr("複製到剪貼簿"))
                        onClicked: {
                            Quickshell.clipboardText = page.exportText;
                            page.notice = page.t(qsTr("已複製到剪貼簿"));
                        }
                    }
                    Button {
                        tokens: page.tokens
                        kind: "subtle"
                        text: page.t(qsTr("關閉"))
                        onClicked: page.exportText = ""
                    }
                }
            }

            TextArea {
                id: importArea
                width: parent.width
                height: 120
                tokens: page.tokens
                accessibleName: page.t(qsTr("要匯入的組合"))
            }

            Row {
                spacing: page.tokens.space
                Button {
                    tokens: page.tokens
                    text: page.t(qsTr("從剪貼簿貼上"))
                    onClicked: importArea.text = Quickshell.clipboardText
                }
                Button {
                    tokens: page.tokens
                    kind: "primary"
                    text: page.t(qsTr("檢查"))
                    enabled: importArea.text.length > 0
                    onClicked: page.validateImport()
                }
            }

            Column {
                visible: !!page.importCheck
                width: parent.width
                spacing: page.tokens.spaceTight

                Text {
                    text: page.importCheck && page.importCheck.importable
                        ? page.t(qsTr("可以匯入。"))
                        : page.t(qsTr("不能匯入，原因如下。"))
                    color: page.importCheck && page.importCheck.importable ? page.tokens.success : page.tokens.warning
                    font.pixelSize: page.tokens.fontBody
                    font.bold: true
                }

                Repeater {
                    model: page.importCheck ? page.importCheck.problems : []
                    Text {
                        required property var modelData
                        width: parent.width
                        wrapMode: Text.WordWrap
                        text: "• " + page.client.key(modelData.detail_key, modelData.detail || {})
                            + (modelData.blocking ? "" : page.t(qsTr("（不影響匯入）")))
                        color: modelData.blocking ? page.tokens.warning : page.tokens.foregroundMuted
                        font.pixelSize: page.tokens.fontBody
                    }
                }

                Row {
                    visible: !!page.importCheck && page.importCheck.importable
                    spacing: page.tokens.space
                    TextField {
                        id: importName
                        tokens: page.tokens
                        placeholder: page.t(qsTr("匯入後的名稱"))
                    }
                    Button {
                        tokens: page.tokens
                        kind: "primary"
                        text: page.t(qsTr("匯入"))
                        onClicked: page.runImport(importName.text)
                    }
                }
            }
        }
    }
}
