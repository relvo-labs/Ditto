//! Inputs and outputs of the G1 capability groups other than profiles and
//! changes: plugins, permissions, appearance, panels, launcher, commands,
//! shortcuts, notifications, layout, session, jobs and tasks.

use std::collections::BTreeMap;

use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::{
    change::HotSwapLevel,
    manifest::{Manifest, PluginKind, TrustLevel},
    participant::FiberState,
    profile::{Appearance, AvatarSettings, HostKind},
    PermissionDeniedReason, UnavailableReason,
};

// ---- plugins ----------------------------------------------------------------

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct PackageSummary {
    pub package_id: String,
    pub version: String,
    pub sha256: String,
    pub source: String,
    pub name: Value,
    pub author: String,
    pub license: String,
    pub plugin_kind: PluginKind,
    pub host_kind: HostKind,
    pub trust_level: TrustLevel,
    pub installed_at: String,
    /// Retained revisions that pin this package; it cannot be removed while
    /// any exists.
    pub referenced_by: u32,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum EntryRuntimeState {
    Active,
    /// Legal and not an error: the named services are not ready yet.
    Pending {
        waiting_for: Vec<String>,
    },
    Loading,
    Failed {
        reason: String,
    },
    Disabled,
    /// Stopped by supervision after repeated failures.
    SupervisorDisabled {
        reason: String,
        at: String,
    },
    Unavailable {
        reason: UnavailableReason,
    },
    /// A Shell provider that is bound but whose slot the Shell has not
    /// reported yet.
    NotReported,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct EntryStatus {
    pub entry_id: String,
    pub package: String,
    pub version: String,
    pub host: HostKind,
    pub slot: Option<String>,
    pub disabled: bool,
    pub state: EntryRuntimeState,
    /// Why it runs: `profile` (enabled in the active Profile).
    pub started_reason: String,
    pub trust_note_key: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq, Default)]
#[serde(deny_unknown_fields)]
pub struct PluginsListInput {}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct PluginsListOutput {
    pub packages: Vec<PackageSummary>,
    pub entries: Vec<EntryStatus>,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct PluginsGetInput {
    pub package_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub version: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct PluginsGetOutput {
    pub package: PackageSummary,
    pub manifest: Manifest,
    /// Every installed version of this package id.
    pub versions: Vec<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct PluginsInspectInput {
    /// Absolute path to a `.dittopkg` file.
    pub path: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct PluginsInspectOutput {
    pub sha256: String,
    pub manifest: Option<Manifest>,
    pub problems: Vec<String>,
    pub already_installed: bool,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct PluginsInstallInput {
    pub path: String,
    /// When given, the package's sha256 must match (the lock a Profile or an
    /// import expects).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub expected_sha256: Option<String>,
    pub idempotency_key: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct PluginsRemoveInput {
    pub package_id: String,
    pub version: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct PluginsRemoveOutput {
    pub removed: bool,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq, Default)]
#[serde(deny_unknown_fields)]
pub struct PluginsDiagnosticsInput {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub entry_id: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq, Default)]
#[serde(deny_unknown_fields)]
pub struct NodeHeap {
    pub heap_used: u64,
    pub external: u64,
    pub array_buffers: u64,
}

/// Process-level figures Core read from `/proc`; hostd's own report is only
/// used for the Node heap, listed separately and never added to these.
#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq, Default)]
#[serde(deny_unknown_fields)]
pub struct ProcessResources {
    pub pid: u32,
    pub pss_kib: Option<u64>,
    pub rss_kib: Option<u64>,
    pub threads: Option<u32>,
    pub fds: Option<u32>,
    pub cpu_ticks: Option<u64>,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct HostStatus {
    /// `running`, `starting`, `stopped`, `crash_loop`, `not_needed`, `rescue_mode`.
    pub state: String,
    pub generation: Option<u64>,
    pub restarts_last_10_min: u32,
    pub process: Option<ProcessResources>,
    pub heap: Option<NodeHeap>,
    pub strategy: Option<String>,
    pub versions: BTreeMap<String, String>,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq, Default)]
#[serde(deny_unknown_fields)]
pub struct RegistrationCounts {
    pub capabilities: u32,
    pub leases: u32,
    pub subscriptions: u32,
    pub effects: u32,
    pub timers: u32,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct EntryDiagnostics {
    pub entry_id: String,
    pub package: String,
    pub version: String,
    pub host: HostKind,
    pub dependencies: Vec<String>,
    pub providers: BTreeMap<String, String>,
    pub fiber_state: Option<FiberState>,
    pub waiting_for: Vec<String>,
    pub registrations: RegistrationCounts,
    pub last_health: Option<String>,
    pub last_rollback: Option<String>,
    pub supervisor_note: Option<String>,
    /// Always set for hostd entries: in-process plugins share one host and
    /// have no memory figure of their own (RUN-08).
    pub shared_host_note_key: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq, Default)]
#[serde(deny_unknown_fields)]
pub struct CoreCounts {
    pub capability_bindings: u32,
    pub leases: u32,
    pub subscriptions: u32,
    pub shell_mounted_providers: u32,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct PluginsDiagnosticsOutput {
    pub host: HostStatus,
    pub entries: Vec<EntryDiagnostics>,
    pub core: CoreCounts,
}

// ---- permissions ------------------------------------------------------------

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Grant {
    pub grant_id: String,
    pub subject: String,
    pub scope: String,
    /// For `files:` grants the Shell shows the file name, never the path, in
    /// exports; the path itself only reaches the process holding the grant.
    pub resource: Option<String>,
    pub granted_at: String,
    pub expires_at: Option<String>,
    pub revoked_at: Option<String>,
    pub granted_by: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct PolicyRow {
    pub subject_kind: String,
    pub scope: String,
    /// `allowed`, `denied` or `grant_required`.
    pub default: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq, Default)]
#[serde(deny_unknown_fields)]
pub struct PermissionsListInput {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub subject: Option<String>,
    #[serde(default)]
    pub include_revoked: bool,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct PermissionsListOutput {
    pub grants: Vec<Grant>,
    pub policy: Vec<PolicyRow>,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct PermissionsCheckInput {
    pub subject: String,
    pub capability_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resource: Option<String>,
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum Decision {
    Allowed,
    Denied,
    NeedsApproval,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct PermissionsCheckOutput {
    pub decision: Decision,
    /// What a call would actually get: G1 has no approval responder, so
    /// `needs_approval` is refused as `approval_unavailable`.
    pub effective: Decision,
    pub reason: Option<PermissionDeniedReason>,
    pub scopes: Vec<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct PermissionsGrantInput {
    pub subject: String,
    pub scope: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resource: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub expires_at: Option<String>,
    pub idempotency_key: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct GrantIdInput {
    pub grant_id: String,
}

// ---- appearance ---------------------------------------------------------------

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq, Default)]
#[serde(deny_unknown_fields)]
pub struct AppearanceGetInput {}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct AppearanceGetOutput {
    pub appearance: Appearance,
    pub avatar: AvatarSettings,
    /// What the Shell last reported as applied; `null` when no Shell reported.
    pub shell_applied: Option<Appearance>,
    pub profile_revision: String,
}

/// Every field optional; the ones given become `set_value` ops of one
/// ChangeSet, so this has preflight, readback and history like any change.
#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Default)]
#[serde(deny_unknown_fields)]
pub struct AppearanceSetInput {
    pub base_revision: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub theme: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tokens: Option<BTreeMap<String, String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reduced_motion: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reduced_transparency: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub low_power_style: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub locale: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub idempotency_key: Option<String>,
}

// ---- panels -----------------------------------------------------------------

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct PanelStatus {
    pub slot: String,
    pub bound_entry: Option<String>,
    pub package: Option<String>,
    pub mounted_entry: Option<String>,
    pub mounted: bool,
    pub visible: bool,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct PanelsListOutput {
    pub shell_connected: bool,
    pub panels: Vec<PanelStatus>,
    pub reported_at: Option<String>,
    /// Where the Shell last reported the character to be; absent when no
    /// Shell has reported a placement. This is the character's readback.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub avatar: Option<crate::participant::AvatarPlacement>,
}

// ---- launcher ---------------------------------------------------------------

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct AppEntry {
    pub app_id: String,
    pub name: String,
    pub generic_name: Option<String>,
    pub icon: Option<String>,
    pub categories: Vec<String>,
    pub keywords: Vec<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct LauncherSearchInput {
    pub query: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub limit: Option<u32>,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq, Default)]
#[serde(deny_unknown_fields)]
pub struct LauncherListInput {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub category: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct LauncherAppsOutput {
    pub apps: Vec<AppEntry>,
    /// The index is a rebuildable cache, not configuration.
    pub indexed_at: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq, Default)]
#[serde(deny_unknown_fields)]
pub struct LauncherLaunchInput {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub app_id: Option<String>,
    /// Opens with the default application for its type (`xdg-mime`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub open_uri: Option<String>,
}

/// Starting a program is observable; a window appearing is not guaranteed,
/// so this never claims success: confirm with `desktop.windows.list`.
#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct LauncherLaunchOutput {
    pub accepted: bool,
    pub operation_id: String,
    pub unit: String,
    pub app_id: String,
}

// ---- commands and shortcuts -------------------------------------------------

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct CommandInfo {
    pub command_id: String,
    /// `core`, `shell`, or an entry id.
    pub owner: String,
    pub title_key: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct CommandsListOutput {
    pub commands: Vec<CommandInfo>,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct CommandsInvokeInput {
    pub command_id: String,
    #[serde(default)]
    pub args: Value,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct CommandsInvokeOutput {
    pub accepted: bool,
    pub owner: String,
    pub operation_id: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct ShortcutInfo {
    pub chord: String,
    pub command: String,
    pub owner: String,
    pub bound: bool,
    pub conflict: bool,
    /// Kept by Core (rescue, lock); a plugin may not declare these.
    pub reserved: bool,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct ShortcutsListOutput {
    pub shortcuts: Vec<ShortcutInfo>,
    /// How shortcuts reach the compositor on this platform (C-16).
    pub binding_path: String,
}

// ---- notifications ----------------------------------------------------------

#[derive(Clone, Copy, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum Urgency {
    Low,
    Normal,
    Critical,
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum PolicyDecision {
    Show,
    Merge,
    Silence,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct NotificationItem {
    pub id: u32,
    pub app_name: String,
    pub summary: String,
    pub body: String,
    pub urgency: Urgency,
    pub decision: PolicyDecision,
    /// Set when the policy could not be asked: the notification is shown and
    /// the area says rules are unavailable (failing open to display).
    pub policy_unavailable: bool,
    pub merged_count: u32,
    pub created_at: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq, Default)]
#[serde(deny_unknown_fields)]
pub struct NotificationsListInput {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub limit: Option<u32>,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct NotificationsListOutput {
    pub notifications: Vec<NotificationItem>,
    pub server_owned: bool,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct NotificationIdInput {
    pub id: u32,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct NotificationsDismissOutput {
    pub dismissed: bool,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct PolicyCounters {
    pub show: u64,
    pub merge: u64,
    pub silence: u64,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct PolicyRecord {
    pub app_name: String,
    pub decision: PolicyDecision,
    pub rule: Option<String>,
    pub at: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct PolicyStatusOutput {
    pub available: bool,
    pub reason: Option<UnavailableReason>,
    pub provider_entry: Option<String>,
    pub counters: Option<PolicyCounters>,
    pub recent: Vec<PolicyRecord>,
    /// Decisions Core made itself (shown) because the policy was unreachable.
    pub fallback_shown: u64,
}

/// What Core asks the `svc.notification_policy` provider, with a 50 ms
/// deadline. Body text is not sent: the rules do not need it.
#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct PolicyDecideInput {
    pub app_name: String,
    pub urgency: Urgency,
    pub at: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct PolicyDecideOutput {
    pub decision: PolicyDecision,
    pub rule: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct PolicyGetOutput {
    pub rules: Value,
    pub counters: PolicyCounters,
    pub recent: Vec<PolicyRecord>,
}

// ---- layout -----------------------------------------------------------------

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct LayoutStrategyInfo {
    pub package: String,
    pub name_key: String,
    pub hot_swap: HotSwapLevel,
    /// False when the compositor cannot switch it while running (C-15): the
    /// switch is then scheduled for the next login and says so.
    pub runtime_switchable: bool,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct LayoutGetOutput {
    pub strategy_entry: Option<String>,
    pub strategy_package: Option<String>,
    pub observed_strategy: Option<String>,
    pub available: Vec<LayoutStrategyInfo>,
    pub workspace_grid: [u32; 2],
    pub rules: Vec<crate::profile::LayoutRule>,
    /// Session-restart changes waiting for the next login.
    pub pending_next_login: Vec<String>,
}

// ---- session ----------------------------------------------------------------

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct SessionState {
    pub locked: bool,
    pub lock_client_running: bool,
    pub preparing_for_sleep: bool,
    pub logind_available: bool,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct SessionActionOutput {
    pub accepted: bool,
    pub operation_id: String,
}

// ---- jobs -------------------------------------------------------------------

#[derive(Clone, Copy, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum JobState {
    Queued,
    Running,
    Succeeded,
    Failed,
    Cancelled,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct Job {
    pub job_id: String,
    pub kind: String,
    pub state: JobState,
    pub progress: Option<f64>,
    pub result: Option<Value>,
    pub error_key: Option<String>,
    pub idempotency_key: Option<String>,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct JobIdInput {
    pub job_id: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct JobsListOutput {
    pub jobs: Vec<Job>,
}

// ---- tasks (provided by the svc.tasks hostd entry) ------------------------

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct Task {
    pub task_id: String,
    pub text: String,
    pub done: bool,
    /// `own` (the plugin's list) or `file:<grant_id>`.
    pub source: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub priority: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct TaskSource {
    pub source: String,
    /// `ok`, `revoked`, `unavailable`.
    pub status: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq, Default)]
#[serde(deny_unknown_fields)]
pub struct TasksListInput {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct TasksListOutput {
    pub tasks: Vec<Task>,
    pub sources: Vec<TaskSource>,
    /// Sample content is labelled, never presented as the user's own.
    pub demo: bool,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct TasksAddInput {
    pub text: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct TasksCompleteInput {
    pub task_id: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct TasksSubscribeOutput {
    pub subscription_id: String,
    pub seq: u64,
    pub snapshot: TasksListOutput,
}

// ---- rescue -----------------------------------------------------------------

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct UnavailableCapability {
    pub capability_id: String,
    pub reason: UnavailableReason,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct RescueStatusOutput {
    pub mode: crate::rpc::CoreMode,
    pub host: HostStatus,
    pub shell_connected: bool,
    pub active_profile: Option<String>,
    pub head_revision: Option<String>,
    pub last_known_good: Option<String>,
    /// Capabilities that depend on Cordis and are not offered right now; the
    /// Shell says so in product language instead of letting them vanish.
    pub unavailable: Vec<UnavailableCapability>,
    /// Changes whose outcome boot recovery decided, newest first.
    pub recovered_changes: Vec<String>,
}

/// `desktop.rescue.resume_shell`: the rescue UI is left and the normal Shell
/// started again. Success is the new Shell's connection, read back by Core.
#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct RescueResumeShellOutput {
    /// The rescue UI was showing when the request came.
    pub was_in_rescue_ui: bool,
    /// The new Shell connected within the capability's deadline.
    pub shell_connected: bool,
}

/// Rescue actions work on the Profile only; they need no plugin code.
#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct RescueDisableInput {
    /// An entry id, or a package id (every entry of that package).
    pub target: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub idempotency_key: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq, Default)]
#[serde(deny_unknown_fields)]
pub struct RescueRestoreInput {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub profile_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub idempotency_key: Option<String>,
}
