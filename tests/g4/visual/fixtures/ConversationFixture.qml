import QtQuick

/// #116 fixture: the ConversationState members the chat and AI settings
/// read, with two labelled states. `scene: "off"` — AI turned off (Core's
/// settings say so). `scene: "active"` — signed in, one finished exchange and
/// a second turn waiting for an approval. No model, no Core: actions are
/// recorded in `calls` and change nothing.
QtObject {
    id: conversation

    property string scene: "off"
    readonly property bool active: scene === "active"
    property var calls: []

    property var settings: ({ enabled: active, provider: "codex-app-server", approval_mode: "ask",
                              model: active ? "fixture-model" : null, reasoning_effort: "low" })
    readonly property bool enabled: settings.enabled === true
    readonly property bool connected: active
    property var provider: active ? ({ authenticated: true, account_label: "fixture@example.invalid",
        rate_limits: { primary: { used_percent: 12 } },
        models: [{ id: "fixture-model", label: "Fixture model", reasoning_efforts: ["low", "medium"], default_effort: "low" }] }) : null
    property bool settingsFailed: false
    property bool providerFailed: false
    property var login: null
    readonly property string taskState: active ? "awaiting" : "offline"
    readonly property string stateText: active ? "需要你的確認" : "AI 對話已關閉；桌面仍可照常操作"
    readonly property string transportText: ""
    readonly property bool turnActive: active
    property bool sending: false
    property bool attaching: false
    property string draft: ""
    property string streamText: ""
    property string errorText: ""
    property string errorDiagnostic: ""
    property bool hasOlder: false
    property string sessionId: "s-fixture"
    property var sessions: [{ session_id: "s-fixture", title: "Dock 調整", created_at: "2026-10-19T08:30:00Z", next_seq: 4 }]
    property var attached: []
    property var previews: ({})
    property var events: active ? [
        { type: "user/message", data: { text: "把 Dock 移到左邊" } },
        { type: "assistant/message", data: { text: "好的。要移動 Dock，我需要先查看目前開啟的視窗與螢幕，這需要你的確認。（fixture 對話，沒有連接模型）" } },
        { type: "user/message", data: { text: "可以，順便讓通知安靜一點" } }
    ] : []

    function record(name, args) { calls = calls.concat([{ call: name, args: args }]); }
    function open() {}
    function setEnabled(value) { record("setEnabled", value); }
    function send() { record("send", draft); }
    function stop() { record("stop"); }
    function newConversation() { record("newConversation"); }
    function selectSession(id, next) { record("selectSession", id); }
    function deleteSession(id) { record("deleteSession", id); }
    function loadOlder() {}
    function attach(kind, path) { record("attach", kind); }
    function detach(id) {}
    function undoChange(id) {}
    function startLogin() { record("startLogin"); }
    function cancelLogin() {}
    function logout() {}
    function useSubscription() {}
    function chooseModel(model, effort) {}
    function setApprovalMode(mode) {}
    function saveApiKey(endpoint, model, secret, done) {}
    function refreshSettings() {}
    function refreshProvider() {}
}
