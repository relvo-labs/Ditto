import QtQuick
import "root:/sdk/Ditto/Ui"

/// Plugin center (G1-SHELL-07): every installed package and every entry of
/// the active composition, with the MOD-01 / RUN-08 fields. A service
/// waiting for another service says which one; it is not an error. Memory is
/// shown per host process: plugins that share a host cannot be measured
/// alone, and the page says so instead of inventing a number. Installing and
/// enabling are separate: installing only adds to the package store (a job);
/// enabling is a ChangeSet with its own change card.
Flickable {
    id: page

    required property var client
    required property var tokens
    property var config: ({})
    property string pageId: "plugins"
    property string entryId: ""
    readonly property Flickable flickable: page
    /// #116 application style (Profile `ui_style`, light recipe); false keeps the existing page.
    readonly property bool jelly: tokens.uiCandidate === true

    contentWidth: width
    contentHeight: column.implicitHeight + tokens.appPagePad * 2
    clip: true
    boundsBehavior: Flickable.StopAtBounds

    property var entries: []
    property var packages: []
    readonly property var filteredPackages: packages.filter(summary => PluginFilter.matches(
        summary, manifestOf(summary.package_id, summary.version), entries, pluginSearch.text,
        value => client.tr.localized(value)))
    property var manifests: ({})
    property var diagnostics: null
    property var grants: []
    property var jobs: ({})
    property var inspected: null
    property string notice: ""
    property string diagnostic: ""
    property var lastRecord: null
    property bool busy: false

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
        client.capability("desktop.plugins.list", {}, function (result) {
            page.entries = result.entries;
            page.packages = result.packages;
            for (const summary of result.packages) {
                if (page.manifests[summary.package_id + "@" + summary.version]) {
                    continue;
                }
                client.capability("desktop.plugins.get", { package_id: summary.package_id, version: summary.version }, function (detail) {
                    const table = Object.assign({}, page.manifests);
                    table[detail.manifest.id + "@" + detail.manifest.version] = detail.manifest;
                    page.manifests = table;
                });
            }
        }, fail);
        client.capability("desktop.plugins.diagnostics", {}, function (result) {
            page.diagnostics = result;
        });
        client.capability("desktop.permissions.list", {}, function (result) {
            page.grants = result.grants;
        });
    }

    Component.onCompleted: reload()

    Connections {
        target: page.client
        function onCapabilitiesReloaded() {
            page.reload();
        }
        function onPanelsReported(panels) {
            page.reload();
        }
        function onProfileChanged(payload) {
            page.reload();
        }
        function onJobUpdated(job) {
            const table = Object.assign({}, page.jobs);
            table[job.job_id] = job;
            page.jobs = table;
            if (job.state === "succeeded" || job.state === "failed") {
                page.reload();
            }
        }
        function onChangeUpdated(change) {
            if (page.lastRecord && change.change_id === page.lastRecord.change_id) {
                client.capability("desktop.changes.get", { change_id: change.change_id }, function (record) {
                    page.lastRecord = record;
                });
            }
        }
    }

    function manifestOf(packageId, version) {
        return manifests[packageId + "@" + version] || null;
    }

    function entriesOf(packageId) {
        return entries.filter(entry => entry.package === packageId);
    }

    function cordisEntries() {
        return entries.filter(entry => entry.host === "cordis" && !entry.disabled);
    }

    function hostName(host) {
        switch (host) {
        case "qml":
            return t(qsTr("桌面介面程序（Shell）"));
        case "cordis":
            return t(qsTr("插件服務宿主"));
        case "core_builtin":
            return t(qsTr("Core 內建"));
        }
        return host;
    }

    function trustName(level) {
        switch (level) {
        case "trusted":
            return t(qsTr("可信"));
        case "community":
            return t(qsTr("社群"));
        case "untrusted":
            return t(qsTr("不受信任"));
        }
        return level;
    }

    function sourceName(source) {
        return source === "builtin" ? t(qsTr("內建")) : source;
    }

    /// PENDING is "waiting for a service", never an error and never a vague
    /// "loading".
    function stateText(state) {
        if (!state) {
            return "";
        }
        switch (state.kind) {
        case "active":
            return t(qsTr("執行中"));
        case "pending":
            return t(qsTr("等待「%1」服務")).arg(client.join(state.waiting_for.map(name => client.tr.has("service." + name) ? client.key("service." + name, {}) : name)));
        case "loading":
            return t(qsTr("正在啟動"));
        case "failed":
            return t(qsTr("沒有啟動成功"));
        case "disabled":
            return t(qsTr("已停用"));
        case "supervisor_disabled":
            return t(qsTr("已自動停用：一再失敗（%1）")).arg(words.time(state.at));
        case "unavailable":
            return t(qsTr("暫不可用：%1")).arg(client.key("unavailable." + state.reason, {}));
        case "not_reported":
            return t(qsTr("尚未回報狀態"));
        }
        return state.kind;
    }

    function stateTone(state) {
        if (!state) {
            return "neutral";
        }
        switch (state.kind) {
        case "active":
            return "good";
        case "pending":
        case "loading":
            return "info";
        case "failed":
        case "supervisor_disabled":
            return "bad";
        case "unavailable":
            return "warn";
        }
        return "neutral";
    }

    function resourceText(entry) {
        if (entry.host === "cordis") {
            const others = cordisEntries().length - 1;
            const process = diagnostics && diagnostics.host ? diagnostics.host.process : null;
            const size = process && process.pss_kib ? t(qsTr("宿主程序 %1 MiB")).arg(Math.round(process.pss_kib / 1024)) : t(qsTr("宿主程序未回報"));
            return t(qsTr("與 %1 個插件共用宿主，無法單獨計量；%2")).arg(Math.max(0, others)).arg(size);
        }
        if (entry.host === "qml") {
            return t(qsTr("在桌面介面程序內執行（同宿主、無隔離），無法單獨計量"));
        }
        return t(qsTr("在 Core 內執行"));
    }

    function propose(ops, done) {
        busy = true;
        notice = t(qsTr("正在套用…"));
        diagnostic = "";
        client.propose(ops, { surface: "plugin_center" }, function (record) {
            page.busy = false;
            page.notice = "";
            page.lastRecord = record;
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

    function setDisabled(entry, disabled) {
        propose([{ op: "set_entry_disabled", entry_id: entry.entry_id, disabled: disabled }]);
    }

    /// The multi-entry area a package can join (status items), or "".
    /// Joining adds a place beside the others; no single slot is taken.
    readonly property var areas: ["ui.status_item", "ui.generated_panel"]
    function areaOf(manifest) {
        if (!manifest || !manifest.slots) {
            return "";
        }
        const found = manifest.slots.find(slot => areas.indexOf(slot) >= 0);
        return found || "";
    }

    function enablePackage(summary) {
        const manifest = manifestOf(summary.package_id, summary.version);
        const entry = { package: summary.package_id, version: summary.version, host: summary.host_kind, config: {}, disabled: false };
        const op = { op: "add_entry", entry: entry };
        const area = summary.host_kind === "qml" ? areaOf(manifest) : "";
        if (area.length > 0) {
            op.slot = area;
        } else if (manifest && manifest.slots && manifest.slots.length === 1 && summary.host_kind === "cordis") {
            op.slot = manifest.slots[0];
        }
        propose([op]);
    }

    function inspect(path) {
        inspected = null;
        client.capability("desktop.plugins.inspect", { path: path.trim() }, function (result) {
            page.inspected = Object.assign({ path: path.trim() }, result);
        }, fail);
    }

    function install() {
        if (!inspected) {
            return;
        }
        client.capability("desktop.plugins.install", { path: inspected.path, expected_sha256: inspected.sha256, idempotency_key: client.newKey("gui") }, function (job) {
            const table = Object.assign({}, page.jobs);
            if (job && job.job_id) {
                table[job.job_id] = job;
            }
            page.jobs = table;
            page.notice = page.t(qsTr("已開始安裝。安裝完成後要另外啟用。"));
            page.inspected = null;
        }, fail);
    }

    function removePackage(summary) {
        client.capability("desktop.plugins.remove", { package_id: summary.package_id, version: summary.version }, function (result) {
            page.notice = result.removed ? page.t(qsTr("已移除套件")) : page.t(qsTr("套件仍被某個組合使用，沒有移除"));
            page.reload();
        }, fail);
    }

    function grant(subject, scope, resource) {
        client.capability("desktop.permissions.grant", { subject: subject, scope: scope.trim(), resource: resource.trim().length > 0 ? resource.trim() : null, idempotency_key: client.newKey("gui") }, function () {
            page.notice = page.t(qsTr("已授予"));
            page.reload();
        }, fail);
    }

    function revoke(grantRow) {
        client.capability("desktop.permissions.revoke", { grant_id: grantRow.grant_id }, function () {
            page.notice = page.t(qsTr("已撤銷授權"));
            page.reload();
        }, fail);
    }

    Column {
        id: column
        x: page.tokens.appPagePad
        y: page.tokens.appPagePad
        width: page.width - page.tokens.appPagePad * 2
        spacing: page.tokens.spaceSection

        Text {
            text: page.t(qsTr("插件中心"))
            color: page.tokens.appInk
            font.pixelSize: page.tokens.appFontHeading
            font.bold: true
            Accessible.role: Accessible.Heading
            Accessible.name: text
        }

        Text {
            visible: page.notice.length > 0
            width: parent.width
            wrapMode: Text.WordWrap
            text: page.notice
            color: page.tokens.appWarning
            font.pixelSize: page.tokens.appFontBody
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

        GeneratedArtifacts {
            width: parent.width
            client: page.client
            tokens: page.tokens
        }

        Section {
            tokens: page.tokens
            title: page.t(qsTr("已安裝的插件"))
            note: page.t(qsTr("可信的桌面元件在同一個桌面介面程序內執行，彼此沒有隔離；服務類插件共用一個插件服務宿主。"))

            Text {
                id: searchLabel
                text: page.t(qsTr("搜尋已安裝的插件"))
                color: page.tokens.appInk
                font.pixelSize: page.tokens.appFontBody
            }

            TextField {
                id: pluginSearch
                objectName: "pluginSearchField"
                width: parent.width
                tokens: page.tokens
                accessibleName: searchLabel.text
                placeholder: page.t(qsTr("名稱、ID、說明或條目"))
                Keys.onEscapePressed: event => {
                    text = "";
                    event.accepted = true;
                }
            }

            Text {
                objectName: "pluginSearchEmpty"
                visible: pluginSearch.text.trim().length > 0 && page.filteredPackages.length === 0
                width: parent.width
                wrapMode: Text.WordWrap
                text: page.t(qsTr("沒有符合「%1」的插件。")).arg(pluginSearch.text)
                color: page.tokens.appInkMuted
                font.pixelSize: page.tokens.appFontBody
                Accessible.role: Accessible.StaticText
                Accessible.name: text
            }

            Repeater {
                objectName: "installedPluginRows"
                model: page.filteredPackages

                Rectangle {
                    id: packageRow
                    required property var modelData
                    readonly property var manifest: page.manifestOf(modelData.package_id, modelData.version)
                    readonly property var packageEntries: page.entriesOf(modelData.package_id)
                    width: parent.width
                    height: packageColumn.implicitHeight + page.tokens.space * 2
                    radius: page.tokens.appPlateRadius
                    color: page.tokens.appPlate
                    border.color: page.tokens.appPlateBorder
                    border.width: 1

                    Column {
                        id: packageColumn
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.margins: page.tokens.space
                        spacing: page.tokens.spaceTight

                        Row {
                            spacing: page.tokens.space
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: page.client.tr.localized(packageRow.modelData.name) || packageRow.modelData.package_id
                                color: page.tokens.appInk
                                font.pixelSize: page.tokens.appFontBody
                                font.bold: true
                            }
                            Badge {
                                visible: packageRow.packageEntries.length === 0
                                anchors.verticalCenter: parent.verticalCenter
                                tokens: page.tokens
                                text: page.t(qsTr("已安裝，未啟用"))
                            }
                        }

                        Text {
                            width: parent.width
                            wrapMode: Text.WordWrap
                            visible: text.length > 0
                            text: packageRow.manifest ? page.client.tr.localized(packageRow.manifest.description) : ""
                            color: page.tokens.appInkMuted
                            font.pixelSize: page.tokens.appFontCaption
                        }

                        Grid {
                            columns: 4
                            columnSpacing: page.tokens.spaceWide
                            rowSpacing: 2
                            Repeater {
                                model: [
                                    [qsTr("版本"), packageRow.modelData.version],
                                    [qsTr("來源"), page.sourceName(packageRow.modelData.source)],
                                    [qsTr("作者"), packageRow.modelData.author],
                                    [qsTr("授權"), packageRow.modelData.license],
                                    [qsTr("宿主"), page.hostName(packageRow.modelData.host_kind)],
                                    [qsTr("信任等級"), page.trustName(packageRow.modelData.trust_level)],
                                    [qsTr("相容性"), packageRow.manifest ? page.t(qsTr("協定 %1")).arg(packageRow.manifest.required_protocol_version)
                                        + (packageRow.manifest.runtime && packageRow.manifest.runtime.qt ? " · Qt " + packageRow.manifest.runtime.qt : "")
                                        + (packageRow.manifest.runtime && packageRow.manifest.runtime.node ? " · Node " + packageRow.manifest.runtime.node : "") : "—"],
                                    [qsTr("可填的位置"), packageRow.manifest && packageRow.manifest.slots ? page.client.join(packageRow.manifest.slots.map(slot => page.client.tr.slotName(slot))) : "—"]
                                ]
                                Text {
                                    required property var modelData
                                    text: page.t(qsTr("%1：%2")).arg(page.t(modelData[0])).arg(modelData[1])
                                    color: page.tokens.appInk
                                    font.pixelSize: page.tokens.appFontCaption
                                }
                            }
                        }

                        Repeater {
                            model: packageRow.packageEntries

                            Column {
                                id: entryColumn
                                required property var modelData
                                width: packageColumn.width
                                spacing: 2

                                Row {
                                    spacing: page.tokens.space
                                    Badge {
                                        anchors.verticalCenter: parent.verticalCenter
                                        tokens: page.tokens
                                        text: page.stateText(entryColumn.modelData.state)
                                        tone: page.stateTone(entryColumn.modelData.state)
                                    }
                                    Text {
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: entryColumn.modelData.slot ? page.t(qsTr("位置：%1")).arg(page.client.tr.slotName(entryColumn.modelData.slot)) : page.t(qsTr("未放在任何位置"))
                                        color: page.tokens.appInk
                                        font.pixelSize: page.tokens.appFontCaption
                                    }
                                    Text {
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: page.t(qsTr("啟動原因：%1")).arg(page.client.tr.has("started." + entryColumn.modelData.started_reason)
                                            ? page.client.key("started." + entryColumn.modelData.started_reason, {}) : entryColumn.modelData.started_reason)
                                        color: page.tokens.appInkMuted
                                        font.pixelSize: page.tokens.appFontCaption
                                    }
                                }

                                Text {
                                    width: parent.width
                                    wrapMode: Text.WordWrap
                                    text: page.client.key(entryColumn.modelData.trust_note_key, {}) + "  ·  " + page.resourceText(entryColumn.modelData)
                                    color: page.tokens.appInkMuted
                                    font.pixelSize: page.tokens.appFontCaption
                                }

                                Text {
                                    visible: entryColumn.modelData.state && entryColumn.modelData.state.kind === "supervisor_disabled"
                                    width: parent.width
                                    wrapMode: Text.WordWrap
                                    text: page.t(qsTr("這個服務連續失敗，已被自動停用，桌面其他部分不受影響。可以查看診斷後重新啟用。"))
                                    color: page.tokens.appWarning
                                    font.pixelSize: page.tokens.appFontCaption
                                }

                                Row {
                                    spacing: page.tokens.space
                                    Button {
                                        visible: !entryColumn.modelData.disabled
                                        tokens: page.tokens
                                        text: page.t(qsTr("停用"))
                                        enabled: !page.busy
                                        onClicked: page.setDisabled(entryColumn.modelData, true)
                                    }
                                    Button {
                                        visible: entryColumn.modelData.disabled
                                        tokens: page.tokens
                                        kind: "primary"
                                        text: page.t(qsTr("重新啟用"))
                                        enabled: !page.busy
                                        onClicked: page.setDisabled(entryColumn.modelData, false)
                                    }
                                }

                                Diagnostics {
                                    width: parent.width
                                    tokens: page.tokens
                                    title: page.t(qsTr("診斷"))
                                    text: {
                                        const found = page.diagnostics ? page.diagnostics.entries.find(item => item.entry_id === entryColumn.modelData.entry_id) : null;
                                        return JSON.stringify({ entry: entryColumn.modelData, diagnostics: found || null }, null, 2);
                                    }
                                }
                            }
                        }

                        Row {
                            spacing: page.tokens.space
                            Button {
                                visible: packageRow.packageEntries.length === 0 && packageRow.modelData.host_kind !== "qml"
                                tokens: page.tokens
                                kind: "primary"
                                text: page.t(qsTr("啟用"))
                                enabled: !page.busy
                                onClicked: page.enablePackage(packageRow.modelData)
                            }
                            // A status item joins the status items beside the
                            // others; it needs no place chosen.
                            Button {
                                visible: packageRow.packageEntries.length === 0 && packageRow.modelData.host_kind === "qml"
                                    && page.areaOf(packageRow.manifest).length > 0
                                tokens: page.tokens
                                kind: "primary"
                                text: page.t(qsTr("顯示在狀態列"))
                                accessibleName: page.t(qsTr("在狀態列顯示「%1」")).arg(page.client.tr.localized(packageRow.modelData.name) || packageRow.modelData.package_id)
                                enabled: !page.busy
                                onClicked: page.enablePackage(packageRow.modelData)
                            }
                            Text {
                                visible: packageRow.packageEntries.length === 0 && packageRow.modelData.host_kind === "qml"
                                    && page.areaOf(packageRow.manifest).length === 0
                                anchors.verticalCenter: parent.verticalCenter
                                text: page.t(qsTr("桌面元件在組合中心選擇要放的位置後啟用。"))
                                color: page.tokens.appInkMuted
                                font.pixelSize: page.tokens.appFontCaption
                            }
                            Button {
                                visible: packageRow.modelData.referenced_by === 0 && packageRow.modelData.source !== "builtin"
                                tokens: page.tokens
                                // A destructive action: its own style in the candidate.
                                kind: page.jelly ? "dangerQuiet" : "subtle"
                                text: page.t(qsTr("移除套件"))
                                onClicked: page.removePackage(packageRow.modelData)
                            }
                        }

                        // Permissions: what the plugin asks for, what is granted.
                        Column {
                            visible: !!packageRow.manifest && (packageRow.manifest.permissions || []).length > 0
                            width: parent.width
                            spacing: 2

                            Text {
                                text: page.t(qsTr("請求的權限：%1")).arg(packageRow.manifest ? page.client.join(packageRow.manifest.permissions || []) : "")
                                color: page.tokens.appInk
                                font.pixelSize: page.tokens.appFontCaption
                            }

                            Repeater {
                                model: page.grants.filter(grantRow => packageRow.packageEntries.some(entry => grantRow.subject === "host:" + entry.entry_id))

                                Row {
                                    required property var modelData
                                    spacing: page.tokens.space
                                    Text {
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: page.t(qsTr("已授予：%1 %2")).arg(modelData.scope).arg(modelData.resource || "")
                                            + (modelData.revoked_at ? page.t(qsTr("（已撤銷）")) : "")
                                        color: page.tokens.appInk
                                        font.pixelSize: page.tokens.appFontCaption
                                    }
                                    Button {
                                        visible: !modelData.revoked_at
                                        tokens: page.tokens
                                        kind: "subtle"
                                        text: page.t(qsTr("撤銷這項授權"))
                                        onClicked: page.revoke(modelData)
                                    }
                                }
                            }

                            Row {
                                visible: packageRow.packageEntries.length > 0
                                spacing: page.tokens.space
                                TextField {
                                    id: scopeField
                                    width: 160
                                    tokens: page.tokens
                                    placeholder: page.t(qsTr("權限範圍"))
                                    text: packageRow.manifest && packageRow.manifest.permissions && packageRow.manifest.permissions.length > 0
                                        ? packageRow.manifest.permissions[0] : ""
                                }
                                TextField {
                                    id: resourceField
                                    width: 260
                                    tokens: page.tokens
                                    placeholder: page.t(qsTr("檔案路徑（檔案權限才需要）"))
                                }
                                Button {
                                    tokens: page.tokens
                                    text: page.t(qsTr("授予"))
                                    onClicked: page.grant("host:" + packageRow.packageEntries[0].entry_id, scopeField.text, resourceField.text)
                                }
                            }
                        }
                    }
                }
            }
        }

        Section {
            tokens: page.tokens
            title: page.t(qsTr("安裝插件"))
            note: page.t(qsTr("G1 只接受內建來源的可信套件。安裝只放進套件庫，不會改變目前的組合。"))

            Row {
                spacing: page.tokens.space
                TextField {
                    id: pathField
                    width: 420
                    tokens: page.tokens
                    placeholder: page.t(qsTr(".dittopkg 檔案的完整路徑"))
                    onAccepted: page.inspect(text)
                }
                Button {
                    tokens: page.tokens
                    text: page.t(qsTr("檢查"))
                    enabled: pathField.text.length > 0
                    onClicked: page.inspect(pathField.text)
                }
            }

            Column {
                visible: !!page.inspected
                width: parent.width
                spacing: 2
                Text {
                    text: page.inspected && page.inspected.manifest
                        ? page.t(qsTr("「%1」%2")).arg(page.client.tr.localized(page.inspected.manifest.name)).arg(page.inspected.manifest.version)
                        : page.t(qsTr("無法讀取這個套件"))
                    color: page.tokens.appInk
                    font.pixelSize: page.tokens.appFontBody
                    font.bold: true
                }
                Text {
                    visible: !!page.inspected && page.inspected.already_installed
                    text: page.t(qsTr("這個版本已經安裝。"))
                    color: page.tokens.appInkMuted
                    font.pixelSize: page.tokens.appFontCaption
                }
                Repeater {
                    model: page.inspected ? page.inspected.problems : []
                    Text {
                        required property var modelData
                        text: "• " + modelData
                        color: page.tokens.appWarning
                        font.pixelSize: page.tokens.appFontCaption
                    }
                }
                Button {
                    visible: !!page.inspected && !!page.inspected.manifest && page.inspected.problems.length === 0 && !page.inspected.already_installed
                    tokens: page.tokens
                    kind: "primary"
                    text: page.t(qsTr("安裝"))
                    onClicked: page.install()
                }
            }

            Repeater {
                model: Object.values(page.jobs)
                Text {
                    required property var modelData
                    text: page.t(qsTr("安裝工作：%1")).arg(modelData.state === "succeeded" ? page.t(qsTr("完成"))
                        : modelData.state === "failed" ? page.t(qsTr("失敗：%1")).arg(page.client.key(modelData.error_key || "install.failed", {}))
                        : modelData.state === "cancelled" ? page.t(qsTr("已取消"))
                        : modelData.progress !== null && modelData.progress !== undefined ? Math.round(modelData.progress * 100) + "%" : page.t(qsTr("進行中")))
                    color: page.tokens.appInk
                    font.pixelSize: page.tokens.appFontCaption
                }
            }
        }

        Section {
            tokens: page.tokens
            title: page.t(qsTr("插件服務宿主"))

            Text {
                width: parent.width
                wrapMode: Text.WordWrap
                text: {
                    const host = page.diagnostics ? page.diagnostics.host : null;
                    if (!host) {
                        return page.t(qsTr("尚未取得宿主狀態"));
                    }
                    const pss = host.process && host.process.pss_kib ? page.t(qsTr("記憶體 %1 MiB（整個宿主程序）")).arg(Math.round(host.process.pss_kib / 1024)) : page.t(qsTr("記憶體未回報"));
                    return page.t(qsTr("狀態：%1；過去 10 分鐘重啟 %2 次；%3")).arg(host.state).arg(host.restarts_last_10_min).arg(pss);
                }
                color: page.tokens.appInk
                font.pixelSize: page.tokens.appFontBody
            }

            Diagnostics {
                width: parent.width
                tokens: page.tokens
                title: page.t(qsTr("診斷"))
                text: page.diagnostics ? JSON.stringify(page.diagnostics, null, 2) : ""
            }
        }
    }
}
