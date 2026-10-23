import QtQuick

/// Created only in ConversationState's scope: `state` is a lexical id,
/// never a property of this facade. No source object or chat state is exported.
/// This is a trusted same-process API boundary, not a sandbox.
QtObject {
    readonly property bool canLogin: state.canLogin
    readonly property bool connected: state.connected
    readonly property bool enabled: state.enabled
    readonly property string errorDiagnostic: state.errorDiagnostic
    readonly property string errorText: state.errorText
    readonly property var login: state.login
    readonly property string loginResultText: state.loginResultText
    readonly property var provider: state.provider
    readonly property bool providerFailed: state.providerFailed
    readonly property bool runtimeControllerUnavailable: state.runtimeControllerUnavailable
    readonly property bool runtimeFailed: state.runtimeFailed
    readonly property string runtimeFailureText: state.runtimeFailureText
    readonly property bool runtimePending: state.runtimePending
    readonly property string runtimeStatusText: state.runtimeStatusText
    readonly property var settings: state.settings
    readonly property bool settingsFailed: state.settingsFailed
    readonly property bool subscriptionUnavailable: state.subscriptionUnavailable
    readonly property string subscriptionUnavailableText: state.subscriptionUnavailableText

    function open() { state.open(); }
    function setEnabled(on) { state.setEnabled(on); }
    function refreshSettings() { state.refreshSettings(); }
    function useSubscription() { state.useSubscription(); }
    function startLogin() { state.startLogin(); }
    function cancelLogin() { state.cancelLogin(); }
    function logout() { state.logout(); }
    function refreshProvider() { state.refreshProvider(); }
    function chooseModel(model, effort) { state.chooseModel(model, effort); }
    function saveApiKey(endpoint, model, key, onDone) { state.saveApiKey(endpoint, model, key, onDone); }
    function setApprovalMode(mode) { state.setApprovalMode(mode); }
}
