use std::{
    fs,
    path::{Path, PathBuf},
};

use ditto_protocol::{
    agent::*, catalog, change::*, host, manifest::Manifest, participant, profile::*, rpc,
    services::*, *,
};
use schemars::JsonSchema;
use serde_json::Value;

fn write_schema<T: JsonSchema>(
    directory: &Path,
    name: &str,
    check: bool,
    written: &mut Vec<String>,
) -> std::io::Result<()> {
    let value = serde_json::to_value(schemars::schema_for!(T))?;
    written.push(format!("{name}.json"));
    write_json(directory.join(format!("{name}.json")), &value, check)
}

fn write_json(path: PathBuf, value: &Value, check: bool) -> std::io::Result<()> {
    let mut contents = serde_json::to_string_pretty(value)?;
    contents.push('\n');
    if check {
        if fs::read_to_string(&path).ok().as_deref() != Some(contents.as_str()) {
            return Err(std::io::Error::other(format!(
                "stale schema: {}",
                path.display()
            )));
        }
        Ok(())
    } else {
        fs::write(path, contents)
    }
}

macro_rules! export {
    ($directory:expr, $check:expr, $written:expr, $($name:literal => $type:ty),+ $(,)?) => {
        $(write_schema::<$type>($directory, $name, $check, $written)?;)+
    };
}

fn main() -> std::io::Result<()> {
    let check = std::env::args().skip(1).any(|arg| arg == "--check");
    let directory = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../schema");
    fs::create_dir_all(&directory)?;
    let mut written = Vec::new();
    let w = &mut written;
    export!(&directory, check, w,
        // G0 desktop types
        "empty" => Empty,
        "window" => Window,
        "workspace" => Workspace,
        "output" => Output,
        "window-id-input" => WindowIdInput,
        "workspace-id-input" => WorkspaceIdInput,
        "window-move-input" => WindowMoveInput,
        "window-resize-input" => WindowResizeInput,
        "window-set-state-input" => WindowSetStateInput,
        "close-request-output" => CloseRequestOutput,
        "outputs-list-output" => OutputsListOutput,
        "workspaces-list-output" => WorkspacesListOutput,
        "windows-list-output" => WindowsListOutput,
        "desktop-snapshot" => DesktopSnapshot,
        "events-subscribe-input" => EventsSubscribeInput,
        "events-subscribe-output" => EventsSubscribeOutput,
        "desktop-event-notification" => DesktopEventNotification,
        "request-meta" => RequestMeta,
        "result-meta" => ResultMeta,
        "capabilities-list-output" => catalog::CapabilitiesListOutput,
        "rpc-request" => rpc::RpcRequest,
        "rpc-response" => rpc::RpcResponse,
        "handshake-input" => rpc::HandshakeInput,
        "handshake-output" => rpc::HandshakeOutput,
        // G2 Core-owned Agent contracts
        "conversation" => Conversation,
        "session-event" => SessionEvent,
        "session-create-input" => SessionCreateInput,
        "session-id-input" => SessionIdInput,
        "sessions-list-output" => SessionsListOutput,
        "session-read-input" => SessionReadInput,
        "session-read-output" => SessionReadOutput,
        "session-open-output" => SessionOpenOutput,
        "session-write-input" => SessionWriteInput,
        "session-append-input" => SessionAppendInput,
        "session-delete-output" => SessionDeleteOutput,
        "profile-upgrade-input" => ProfileUpgradeInput,
        "agent-preferences" => AgentPreferences,
        "preferences-patch-input" => PreferencesPatchInput,
        "turn-submit-input" => TurnSubmitInput,
        "turn" => Turn,
        "turn-id-input" => TurnIdInput,
        "turn-trace-output" => TurnTraceOutput,
        "tool-trace" => ToolTrace,
        "tool-outcome" => ToolOutcome,
        "turn-complete-input" => TurnCompleteInput,
        "turn-claim-output" => TurnClaimOutput,
        "recent-change" => RecentChange,
        "context-acquire-input" => ContextAcquireInput,
        "context-reference" => ContextReference,
        "context-id-input" => ContextIdInput,
        "context-preview-output" => ContextPreviewOutput,
        "context-payload" => ContextPayload,
        "approvals-list-output" => ApprovalsListOutput,
        "credential-create-input" => CredentialCreateInput,
        "turn-stream-input" => TurnStreamInput,
        "credential-ref-input" => CredentialRefInput,
        "credential-status" => CredentialStatus,
        "credential-resolve-input" => CredentialResolveInput,
        "credential-resolve-output" => CredentialResolveOutput,
        "tool-intent-input" => ToolIntentInput,
        "tool-intent" => ToolIntent,
        "tool-abandon-input" => ToolAbandonInput,
        "agent-runtime-status" => AgentRuntimeStatus,
        "agent-ready-input" => AgentReadyInput,
        "provider-login-input" => ProviderLoginInput,
        "provider-cancel-login-input" => ProviderCancelLoginInput,
        "provider-login-output" => ProviderLoginOutput,
        "provider-action-output" => ProviderActionOutput,
        "provider-status" => ProviderStatus,
        "provider-model" => ProviderModel,
        "provider-rate-window" => ProviderRateWindow,
        "provider-rate-limits" => ProviderRateLimits,
        "approval-request-input" => ApprovalRequestInput,
        "approval" => Approval,
        "approval-id-input" => ApprovalIdInput,
        "approval-decide-input" => ApprovalDecideInput,
        // profiles
        "profile-document" => ProfileDocument,
        "profile-summary" => ProfileSummary,
        "revision-summary" => RevisionSummary,
        "profiles-list-output" => ProfilesListOutput,
        "profiles-get-input" => ProfilesGetInput,
        "profiles-get-output" => ProfilesGetOutput,
        "profiles-create-input" => ProfilesCreateInput,
        "profiles-duplicate-input" => ProfilesDuplicateInput,
        "profiles-rename-input" => ProfilesRenameInput,
        "profile-id-input" => ProfileIdInput,
        "profiles-diff-input" => ProfilesDiffInput,
        "profiles-diff-output" => ProfilesDiffOutput,
        "profile-export" => ProfileExport,
        "profiles-export-output" => ProfilesExportOutput,
        "profiles-import-validate-input" => ProfilesImportValidateInput,
        "profiles-import-validate-output" => ProfilesImportValidateOutput,
        "profiles-import-input" => ProfilesImportInput,
        // changes
        "change-op" => ChangeOp,
        "changes-propose-input" => ChangesProposeInput,
        "change-record" => ChangeRecord,
        "change-summary" => ChangeSummary,
        "changes-get-input" => ChangesGetInput,
        "changes-list-input" => ChangesListInput,
        "changes-list-output" => ChangesListOutput,
        "change-id-input" => ChangeIdInput,
        // participants and the Shell's control methods
        "participant-prepare-params" => participant::PrepareParams,
        "participant-step-report" => participant::StepReport,
        "participant-change-ref" => participant::ChangeRef,
        "participant-state-params" => participant::StateParams,
        "participant-state-output" => participant::StateOutput,
        "participant-projection" => participant::Projection,
        "participant-observation" => participant::Observation,
        "shell-report-input" => participant::ShellObservation,
        "shell-command-params" => participant::ShellCommandParams,
        // hostd
        "host-hello-input" => host::HelloInput,
        "host-hello-output" => host::HelloOutput,
        "host-register-input" => host::RegisterInput,
        "host-register-output" => host::RegisterOutput,
        "host-revoke-input" => host::RevokeInput,
        "host-renew-input" => host::RenewInput,
        "host-renew-output" => host::RenewOutput,
        "host-event-input" => host::EventInput,
        "host-event-output" => host::EventOutput,
        "host-entry-state-input" => host::EntryStateInput,
        "host-resources-input" => host::ResourcesInput,
        "host-invoke-params" => host::InvokeParams,
        "host-permission-revoked-params" => host::PermissionRevokedParams,
        "manifest" => Manifest,
        // services
        "plugins-list-input" => PluginsListInput,
        "plugins-list-output" => PluginsListOutput,
        "plugins-get-input" => PluginsGetInput,
        "plugins-get-output" => PluginsGetOutput,
        "plugins-inspect-input" => PluginsInspectInput,
        "plugins-inspect-output" => PluginsInspectOutput,
        "plugins-install-input" => PluginsInstallInput,
        "plugins-remove-input" => PluginsRemoveInput,
        "plugins-remove-output" => PluginsRemoveOutput,
        "plugins-diagnostics-input" => PluginsDiagnosticsInput,
        "plugins-diagnostics-output" => PluginsDiagnosticsOutput,
        "permissions-list-input" => PermissionsListInput,
        "permissions-list-output" => PermissionsListOutput,
        "permissions-check-input" => PermissionsCheckInput,
        "permissions-check-output" => PermissionsCheckOutput,
        "permissions-grant-input" => PermissionsGrantInput,
        "grant" => Grant,
        "grant-id-input" => GrantIdInput,
        "appearance-get-input" => AppearanceGetInput,
        "appearance-get-output" => AppearanceGetOutput,
        "appearance-set-input" => AppearanceSetInput,
        "panels-list-output" => PanelsListOutput,
        "launcher-search-input" => LauncherSearchInput,
        "launcher-list-input" => LauncherListInput,
        "launcher-apps-output" => LauncherAppsOutput,
        "launcher-launch-input" => LauncherLaunchInput,
        "launcher-launch-output" => LauncherLaunchOutput,
        "commands-list-output" => CommandsListOutput,
        "commands-invoke-input" => CommandsInvokeInput,
        "commands-invoke-output" => CommandsInvokeOutput,
        "shortcuts-list-output" => ShortcutsListOutput,
        "notifications-list-input" => NotificationsListInput,
        "notifications-list-output" => NotificationsListOutput,
        "notification-id-input" => NotificationIdInput,
        "notifications-dismiss-output" => NotificationsDismissOutput,
        "policy-status-output" => PolicyStatusOutput,
        "policy-decide-input" => PolicyDecideInput,
        "policy-decide-output" => PolicyDecideOutput,
        "policy-get-output" => PolicyGetOutput,
        "layout-get-output" => LayoutGetOutput,
        "session-state" => SessionState,
        "session-action-output" => SessionActionOutput,
        "job" => Job,
        "job-id-input" => JobIdInput,
        "jobs-list-output" => JobsListOutput,
        "task" => Task,
        "tasks-list-input" => TasksListInput,
        "tasks-list-output" => TasksListOutput,
        "tasks-add-input" => TasksAddInput,
        "tasks-complete-input" => TasksCompleteInput,
        "tasks-subscribe-output" => TasksSubscribeOutput,
        "rescue-status-output" => RescueStatusOutput,
        "rescue-disable-input" => RescueDisableInput,
        "rescue-restore-input" => RescueRestoreInput,
    );
    written.push("catalog.json".into());
    write_json(
        directory.join("catalog.json"),
        &serde_json::to_value(catalog::catalog())?,
        check,
    )?;
    // A schema file nobody exports any more is stale too.
    for entry in fs::read_dir(&directory)? {
        let name = entry?.file_name().to_string_lossy().into_owned();
        if name.ends_with(".json") && !written.contains(&name) {
            if check {
                return Err(std::io::Error::other(format!("orphan schema: {name}")));
            }
            fs::remove_file(directory.join(&name))?;
        }
    }
    Ok(())
}
