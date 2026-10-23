import QtQuick
import "../ui"

/// AI settings (G2-SHELL-04). Two ways to connect a model — the Codex
/// subscription (sign in with the official browser page; no key field) or an
/// API key kept in the keyring — plus the model, how approvals are asked and
/// turning AI off. Every change is Core's settings revision; a key goes to
/// the keyring and only its reference comes back. The desktop works the same
/// with AI off.
Flickable {
    id: page

    required property var client
    required property var tokens
    /// #116 application style (Profile `ui_style`, light recipe); false keeps the existing page.
    readonly property bool jelly: tokens.uiCandidate === true
    property var aiSettings: null

    contentWidth: width
    contentHeight: column.implicitHeight + tokens.appPagePad * 2
    clip: true
    boundsBehavior: Flickable.StopAtBounds

    function t(source) {
        return client.t(source);
    }

    readonly property var settings: aiSettings ? aiSettings.settings : null
    readonly property var provider: aiSettings ? aiSettings.provider : null
    readonly property bool direct: !!settings && settings.provider === "direct-model"
    property string keyNotice: ""

    // Centers.qml binds the facade for the built-in page; the container
    // supplies it after creation for registered packages.
    onAiSettingsChanged: { if (aiSettings) aiSettings.open(); }

    Column {
        id: column
        x: page.tokens.appPagePad
        y: page.tokens.appPagePad
        width: page.width - page.tokens.appPagePad * 2
        spacing: page.tokens.spaceSection

        Text {
            text: page.t(qsTr("AI 設定"))
            color: page.tokens.appInk
            font.pixelSize: page.tokens.appFontHeading
            font.bold: true
        }

        Section {
            tokens: page.tokens
            title: page.t(qsTr("AI 對話"))
            note: page.t(qsTr("關閉時不連接模型；桌面、設定中心與救援照常使用。"))
            // Until Core's settings are read the switch is not shown at all:
            // an unread or unreadable setting is neither 開 nor 關.
            Toggle {
                visible: !!page.settings
                tokens: page.tokens
                text: page.t(qsTr("啟用 AI 對話"))
                labelOn: page.t(qsTr("開"))
                labelOff: page.t(qsTr("關"))
                checked: (page.aiSettings ? page.aiSettings.enabled : false)
                enabled: !!page.settings
                onToggled: value => page.aiSettings && page.aiSettings.setEnabled(value)
            }
            Row {
                visible: !page.settings
                width: parent.width
                spacing: page.tokens.space
                Text {
                    objectName: "aiSettingsStatus"
                    anchors.verticalCenter: parent.verticalCenter
                    width: Math.min(implicitWidth, parent.width - (settingsRetry.visible ? settingsRetry.width + parent.spacing : 0))
                    wrapMode: Text.WordWrap
                    text: page.client.online === false
                        ? page.t(qsTr("桌面服務未連線；連線後會再讀取 AI 設定。"))
                        : (page.aiSettings ? page.aiSettings.settingsFailed : false)
                            ? page.t(qsTr("無法讀取 AI 設定，目前無法確認開或關。"))
                            : page.t(qsTr("正在讀取 AI 設定…"))
                    color: page.tokens.appInk
                    font.pixelSize: page.tokens.appFontBody
                    Accessible.role: Accessible.StaticText
                    Accessible.name: text
                }
                Button {
                    id: settingsRetry
                    objectName: "aiSettingsRetry"
                    visible: page.client.online !== false && (page.aiSettings ? page.aiSettings.settingsFailed : false)
                    tokens: page.tokens
                    text: page.t(qsTr("重新讀取"))
                    onClicked: page.aiSettings && page.aiSettings.refreshSettings()
                }
            }
        }

        Section {
            tokens: page.tokens
            title: page.t(qsTr("連接方式"))
            Choice {
                tokens: page.tokens
                accessibleName: page.t(qsTr("連接方式"))
                options: [
                    { value: "codex-app-server", label: page.t(qsTr("Codex 訂閱")) },
                    { value: "direct-model", label: page.t(qsTr("API 金鑰")) }
                ]
                value: page.settings ? page.settings.provider : "codex-app-server"
                onChosen: v => { if (!page.aiSettings) return; if (v === "codex-app-server") page.aiSettings.useSubscription(); else apiForm.visible = true; }
            }
        }

        // ---- Codex subscription ------------------------------------------------
        Section {
            tokens: page.tokens
            visible: !page.direct
            title: page.t(qsTr("Codex 訂閱"))
            note: page.t(qsTr("在瀏覽器以官方頁面登入並輸入代碼。登入資料存在系統鑰匙圈；Ditto 不讀取、不顯示它。額度用完時會等待重設，不會改用付費 API。"))

            Text {
                objectName: "aiProviderStatus"
                width: parent.width
                wrapMode: Text.WordWrap
                text: (page.aiSettings ? page.aiSettings.enabled : false) && (page.aiSettings ? page.aiSettings.subscriptionUnavailable : false)
                    ? (page.aiSettings ? page.aiSettings.subscriptionUnavailableText : "")
                    : !page.provider
                    ? (!page.settings ? page.t(qsTr("讀取 AI 設定後才能確認模型連線。"))
                        : !(page.aiSettings ? page.aiSettings.enabled : false) ? page.t(qsTr("尚未連線；開啟 AI 對話後會在需要時啟動。"))
                        : (page.aiSettings ? page.aiSettings.providerFailed : false) ? page.t(qsTr("無法讀取模型連線狀態；目前無法確認是否已登入。"))
                        : page.t(qsTr("正在讀取模型連線狀態…")))
                    : (page.aiSettings ? page.aiSettings.subscriptionUnavailable : false) ? (page.aiSettings ? page.aiSettings.subscriptionUnavailableText : "")
                    : (page.aiSettings ? page.aiSettings.enabled : false) && page.provider.authenticated && !(page.aiSettings ? page.aiSettings.connected : false)
                        ? (page.aiSettings ? page.aiSettings.runtimeStatusText : "")
                    : page.provider.authenticated
                        ? page.t(qsTr("已登入：%1")).arg(page.provider.account_label || page.t(qsTr("（未提供帳號名稱）")))
                        : (page.aiSettings ? page.aiSettings.login : null) ? page.t(qsTr("在瀏覽器開啟 %1 登入，並輸入代碼：%2")).arg((page.aiSettings ? page.aiSettings.login : null).auth_url).arg((page.aiSettings ? page.aiSettings.login : null).user_code) : page.t(qsTr("尚未登入"))
                color: page.tokens.appInk
                font.pixelSize: page.tokens.appFontBody
            }
            Text {
                objectName: "aiLoginResult"
                visible: ((page.aiSettings ? page.aiSettings.loginResultText : "") || "").length > 0
                width: parent.width
                wrapMode: Text.WordWrap
                text: (page.aiSettings ? page.aiSettings.loginResultText : "") || ""
                color: page.tokens.appInkMuted
                font.pixelSize: page.tokens.appFontBody
            }
            Text {
                visible: !!page.provider && page.provider.authenticated
                width: parent.width
                wrapMode: Text.WordWrap
                text: {
                    const limits = page.provider ? page.provider.rate_limits : null;
                    if (!limits || !limits.primary) {
                        return page.t(qsTr("尚無配額資料"));
                    }
                    const reset = limits.primary.resets_at_ms ? new Date(limits.primary.resets_at_ms).toLocaleString(Qt.locale(), "M/d HH:mm") : page.t(qsTr("未知"));
                    return page.t(qsTr("額度已用 %1%，%2 重設")).arg(Math.round(limits.primary.used_percent)).arg(reset);
                }
                color: page.tokens.appInkMuted
                font.pixelSize: page.tokens.appFontCaption
            }
            Row {
                spacing: page.tokens.space
                Button {
                    visible: (page.aiSettings ? page.aiSettings.canLogin : false) && !(page.aiSettings ? page.aiSettings.login : null)
                    tokens: page.tokens
                    kind: "primary"
                    text: page.t(qsTr("使用 Codex 訂閱登入"))
                    onClicked: page.aiSettings && page.aiSettings.startLogin()
                }
                Button {
                    visible: !!(page.aiSettings ? page.aiSettings.login : null)
                    tokens: page.tokens
                    text: page.t(qsTr("取消登入"))
                    onClicked: page.aiSettings && page.aiSettings.cancelLogin()
                }
                Button {
                    visible: !!page.provider && page.provider.authenticated
                    tokens: page.tokens
                    kind: "subtle"
                    text: page.t(qsTr("登出"))
                    onClicked: page.aiSettings && page.aiSettings.logout()
                }
                Button {
                    objectName: "aiProviderRetry"
                    visible: !page.provider && (page.aiSettings ? page.aiSettings.enabled : false) && (page.aiSettings ? page.aiSettings.providerFailed : false)
                    tokens: page.tokens
                    text: page.t(qsTr("重新讀取"))
                    onClicked: page.aiSettings && page.aiSettings.refreshProvider()
                }
            }
            Text {
                visible: models.options.length > 0
                text: page.t(qsTr("模型"))
                color: page.tokens.appInk
                font.pixelSize: page.tokens.appFontBody
            }
            Choice {
                id: models
                tokens: page.tokens
                maxWidth: parent.width
                accessibleName: page.t(qsTr("模型"))
                options: (page.provider && page.provider.models ? page.provider.models : []).map(m => ({ value: m.id, label: m.label }))
                value: page.settings ? page.settings.model : null
                onChosen: v => {
                    if (!page.aiSettings) return;
                    const model = page.provider.models.find(m => m.id === v);
                    page.aiSettings.chooseModel(v, model && model.reasoning_efforts.indexOf("low") >= 0 ? "low" : (model ? model.default_effort : null));
                }
            }
            Choice {
                visible: options.length > 0
                tokens: page.tokens
                accessibleName: page.t(qsTr("思考深度"))
                options: {
                    const model = page.provider && page.settings ? (page.provider.models || []).find(m => m.id === page.settings.model) : null;
                    return model ? model.reasoning_efforts.map(e => ({ value: e, label: e })) : [];
                }
                value: page.settings ? page.settings.reasoning_effort : null
                onChosen: v => page.aiSettings && page.aiSettings.chooseModel(page.settings.model, v)
            }
        }

        // ---- API key ------------------------------------------------------------
        Section {
            id: apiForm
            tokens: page.tokens
            visible: page.direct
            title: page.t(qsTr("API 金鑰連線"))
            note: page.t(qsTr("金鑰直接存進系統鑰匙圈，設定裡只留它的代號；端點必須是 HTTPS（本機除外）。費用依供應商計價，Ditto 尚無費率資料。"))

            Text {
                objectName: "aiRuntimeStatus"
                visible: (page.aiSettings ? page.aiSettings.enabled : false) && ((page.aiSettings ? page.aiSettings.runtimeControllerUnavailable : false)
                    || (page.aiSettings ? page.aiSettings.runtimePending : false) || (page.aiSettings ? page.aiSettings.runtimeFailed : false))
                width: parent.width
                wrapMode: Text.WordWrap
                text: (page.aiSettings ? page.aiSettings.runtimeControllerUnavailable : false) ? (page.aiSettings ? page.aiSettings.runtimeFailureText : "") : (page.aiSettings ? page.aiSettings.runtimeStatusText : "")
                color: page.tokens.appInk
                font.pixelSize: page.tokens.appFontBody
            }

            TextField {
                id: endpoint
                width: Math.min(parent.width, 520)
                tokens: page.tokens
                placeholder: "https://api.example.com/v1"
                accessibleName: page.t(qsTr("端點"))
                text: page.settings && page.settings.endpoint ? page.settings.endpoint : ""
            }
            TextField {
                id: model
                width: Math.min(parent.width, 520)
                tokens: page.tokens
                placeholder: page.t(qsTr("模型名稱"))
                accessibleName: page.t(qsTr("模型名稱"))
                text: page.direct && page.settings && page.settings.model ? page.settings.model : ""
            }
            TextField {
                id: key
                width: Math.min(parent.width, 520)
                tokens: page.tokens
                secret: true
                placeholder: page.direct && page.settings && page.settings.auth ? page.t(qsTr("已儲存；輸入新金鑰以更換")) : page.t(qsTr("API 金鑰"))
                accessibleName: page.t(qsTr("API 金鑰"))
            }
            Row {
                spacing: page.tokens.space
                Button {
                    tokens: page.tokens
                    kind: "primary"
                    text: page.t(qsTr("儲存並使用"))
                    enabled: endpoint.text.length > 0 && key.text.length > 0
                    onClicked: {
                        if (!page.aiSettings) return;
                        const secret = key.text;
                        key.text = "";
                        page.aiSettings.saveApiKey(endpoint.text, model.text, secret, function () {
                            page.keyNotice = page.t(qsTr("已存入鑰匙圈。"));
                        });
                    }
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: page.keyNotice
                    color: page.tokens.appInkMuted
                    font.pixelSize: page.tokens.appFontCaption
                }
            }
        }

        Section {
            tokens: page.tokens
            title: page.t(qsTr("確認方式"))
            note: page.t(qsTr("Ditto 想用尚未授權的能力（例如讀取視窗清單）時：詢問你一次，或一律不詢問並拒絕。可逆的桌面設定不會每次詢問。"))
            Choice {
                tokens: page.tokens
                accessibleName: page.t(qsTr("確認方式"))
                options: [
                    { value: "ask", label: page.t(qsTr("詢問我")) },
                    { value: "never", label: page.t(qsTr("不要詢問，直接拒絕")) }
                ]
                value: page.settings ? page.settings.approval_mode : "ask"
                onChosen: v => page.aiSettings && page.aiSettings.setApprovalMode(v)
            }
        }

        Text {
            visible: (page.aiSettings ? page.aiSettings.errorText : "").length > 0
            width: parent.width
            wrapMode: Text.WordWrap
            text: (page.aiSettings ? page.aiSettings.errorText : "")
            color: page.tokens.appDanger
            font.pixelSize: page.tokens.appFontCaption
        }
        Diagnostics {
            width: parent.width
            tokens: page.tokens
            title: page.t(qsTr("診斷"))
            text: (page.aiSettings ? page.aiSettings.errorDiagnostic : "")
        }
    }
}
