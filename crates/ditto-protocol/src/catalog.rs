use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::{
    change::{
        ChangeIdInput, ChangeRecord, ChangesGetInput, ChangesListInput, ChangesListOutput,
        ChangesProposeInput,
    },
    profile::{
        ProfileIdInput, ProfileSummary, ProfilesCreateInput, ProfilesDiffInput, ProfilesDiffOutput,
        ProfilesDuplicateInput, ProfilesExportOutput, ProfilesGetInput, ProfilesGetOutput,
        ProfilesImportInput, ProfilesImportValidateInput, ProfilesImportValidateOutput,
        ProfilesListInput, ProfilesListOutput, ProfilesRenameInput,
    },
    services::*,
    CloseRequestOutput, Empty, ErrorName, EventsSubscribeInput, EventsSubscribeOutput,
    OutputsListOutput, UnavailableReason, Window, WindowIdInput, WindowMoveInput,
    WindowResizeInput, WindowSetStateInput, WindowsListOutput, Workspace, WorkspaceIdInput,
    WorkspacesListOutput,
};

/// A capability contract. `availability` is the only runtime-resolved field:
/// the exported catalog declares what a capability depends on (a matrix row
/// or a provider slot), and Core fills in what is actually offered.
#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct CapabilityDescriptor {
    pub capability_id: String,
    pub version: String,
    pub input_schema: Value,
    pub output_schema: Value,
    pub errors: Vec<ErrorName>,
    /// Never empty from 0.2 on: every call goes through one authorization
    /// entry point, and an empty scope would be an unreviewed default.
    pub resource_scope: Vec<String>,
    pub cancellable: bool,
    pub idempotency: Idempotency,
    pub timeout_ms: Timeout,
    pub readback: Option<String>,
    pub claimable: bool,
    /// `core`, `compositor-adapter`, `system`, `shell` or `hostd`; the
    /// served catalog names the entry: `hostd:<entry_id>`.
    pub provider: String,
    pub availability: Availability,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
pub enum Idempotency {
    None,
    KeyBased,
    Natural,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Timeout {
    pub default_ms: u64,
    pub max_ms: u64,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Availability {
    Always,
    /// Resolved when Core runs; the exported catalog cannot know it, so it
    /// names the capability-matrix row or the provider slot instead.
    ResolvedAtRuntime {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        matrix_row: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        slot: Option<String>,
    },
    DependsOnCompositor {
        matrix_row: String,
        available: bool,
        reason: Option<String>,
        /// Compositor-specific path this capability is bound to, when no
        /// neutral Wayland protocol covers it.
        bound_to: Option<String>,
    },
    DependsOnProvider {
        slot: String,
        available: bool,
        reason: Option<UnavailableReason>,
        entry_id: Option<String>,
    },
    DependsOnSystem {
        component: String,
        available: bool,
        reason: Option<UnavailableReason>,
    },
}

impl Availability {
    pub fn is_available(&self) -> bool {
        match self {
            Self::Always => true,
            Self::ResolvedAtRuntime { .. } => false,
            Self::DependsOnCompositor { available, .. }
            | Self::DependsOnProvider { available, .. }
            | Self::DependsOnSystem { available, .. } => *available,
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct CapabilitiesListOutput {
    pub catalog_revision: u64,
    pub capabilities: Vec<CapabilityDescriptor>,
}

pub const CATALOG_REVISION: u64 = 6;

// G0
pub const CAPABILITIES_LIST: &str = "desktop.capabilities.list";
pub const OUTPUTS_LIST: &str = "desktop.outputs.list";
pub const WORKSPACES_LIST: &str = "desktop.workspaces.list";
pub const WORKSPACES_GET: &str = "desktop.workspaces.get";
pub const WORKSPACES_ACTIVATE: &str = "desktop.workspaces.activate";
pub const WINDOWS_LIST: &str = "desktop.windows.list";
pub const WINDOWS_GET: &str = "desktop.windows.get";
pub const WINDOWS_FOCUS: &str = "desktop.windows.focus";
pub const WINDOWS_MOVE: &str = "desktop.windows.move";
pub const WINDOWS_RESIZE: &str = "desktop.windows.resize";
pub const WINDOWS_SET_STATE: &str = "desktop.windows.set_state";
pub const WINDOWS_CLOSE_REQUEST: &str = "desktop.windows.close_request";
pub const EVENTS_SUBSCRIBE: &str = "desktop.events.subscribe";
// profiles
pub const PROFILES_LIST: &str = "desktop.profiles.list";
pub const PROFILES_GET: &str = "desktop.profiles.get";
pub const PROFILES_CREATE: &str = "desktop.profiles.create";
pub const PROFILES_DUPLICATE: &str = "desktop.profiles.duplicate";
pub const PROFILES_RENAME: &str = "desktop.profiles.rename";
pub const PROFILES_DELETE: &str = "desktop.profiles.delete";
pub const PROFILES_DIFF: &str = "desktop.profiles.diff";
pub const PROFILES_EXPORT: &str = "desktop.profiles.export";
pub const PROFILES_IMPORT_VALIDATE: &str = "desktop.profiles.import_validate";
pub const PROFILES_IMPORT: &str = "desktop.profiles.import";
// changes
pub const CHANGES_PROPOSE: &str = "desktop.changes.propose";
pub const CHANGES_GET: &str = "desktop.changes.get";
pub const CHANGES_LIST: &str = "desktop.changes.list";
pub const CHANGES_CANCEL: &str = "desktop.changes.cancel";
pub const CHANGES_UNDO: &str = "desktop.changes.undo";
pub const CHANGES_CONFIRM: &str = "desktop.changes.confirm";
// plugins
pub const PLUGINS_LIST: &str = "desktop.plugins.list";
pub const PLUGINS_GET: &str = "desktop.plugins.get";
pub const PLUGINS_INSPECT: &str = "desktop.plugins.inspect";
pub const PLUGINS_INSTALL: &str = "desktop.plugins.install";
pub const PLUGINS_REMOVE: &str = "desktop.plugins.remove";
pub const PLUGINS_DIAGNOSTICS: &str = "desktop.plugins.diagnostics";
pub const DEVELOPMENT_CREATE: &str = "desktop.plugins.development.create";
pub const DEVELOPMENT_GET: &str = "desktop.plugins.development.get";
pub const DEVELOPMENT_LIST: &str = "desktop.plugins.development.list";
pub const DEVELOPMENT_VALIDATE: &str = "desktop.plugins.development.validate";
pub const DEVELOPMENT_PREVIEW: &str = "desktop.plugins.development.preview";
pub const DEVELOPMENT_PUBLISH: &str = "desktop.plugins.development.publish";
pub const DEVELOPMENT_ACTIVATE: &str = "desktop.plugins.development.activate";
pub const DEVELOPMENT_DATA_GET: &str = "desktop.plugins.development.data_get";
pub const DEVELOPMENT_DATA_WRITE: &str = "desktop.plugins.development.data_write";
// permissions
pub const PERMISSIONS_LIST: &str = "desktop.permissions.list";
pub const PERMISSIONS_CHECK: &str = "desktop.permissions.check";
pub const PERMISSIONS_GRANT: &str = "desktop.permissions.grant";
pub const PERMISSIONS_REVOKE: &str = "desktop.permissions.revoke";
// appearance, panels, layout, shortcuts, commands
pub const APPEARANCE_GET: &str = "desktop.appearance.get";
pub const APPEARANCE_SET: &str = "desktop.appearance.set";
pub const PANELS_LIST: &str = "desktop.panels.list";
pub const LAYOUT_GET: &str = "desktop.layout.get";
pub const SHORTCUTS_LIST: &str = "desktop.shortcuts.list";
pub const COMMANDS_LIST: &str = "desktop.commands.list";
pub const COMMANDS_INVOKE: &str = "desktop.commands.invoke";
// launcher
pub const LAUNCHER_SEARCH: &str = "desktop.launcher.search";
pub const LAUNCHER_LIST_APPS: &str = "desktop.launcher.list_apps";
pub const LAUNCHER_LAUNCH: &str = "desktop.launcher.launch";
// notifications
pub const NOTIFICATIONS_LIST: &str = "desktop.notifications.list";
pub const NOTIFICATIONS_DISMISS: &str = "desktop.notifications.dismiss";
pub const NOTIFICATIONS_POLICY_STATUS: &str = "desktop.notifications.policy_status";
pub const NOTIFICATIONS_POLICY_DECIDE: &str = "desktop.notifications.policy.decide";
pub const NOTIFICATIONS_POLICY_GET: &str = "desktop.notifications.policy.get";
// session
pub const SESSION_STATE: &str = "desktop.session.state";
pub const SESSION_LOCK: &str = "desktop.session.lock";
pub const SESSION_LOGOUT: &str = "desktop.session.logout";
pub const SESSION_SUSPEND: &str = "desktop.session.suspend";
pub const SESSION_POWEROFF: &str = "desktop.session.poweroff";
// jobs
pub const JOBS_GET: &str = "desktop.jobs.get";
pub const JOBS_LIST: &str = "desktop.jobs.list";
pub const JOBS_CANCEL: &str = "desktop.jobs.cancel";
pub const JOBS_SUBMIT: &str = "desktop.jobs.submit";
// tasks
pub const TASKS_LIST: &str = "desktop.tasks.list";
pub const TASKS_ADD: &str = "desktop.tasks.add";
pub const TASKS_COMPLETE: &str = "desktop.tasks.complete";
pub const TASKS_SUBSCRIBE: &str = "desktop.tasks.subscribe";
// rescue
pub const RESCUE_STATUS: &str = "desktop.rescue.status";
pub const RESCUE_DISABLE: &str = "desktop.rescue.disable";
pub const RESCUE_RESTORE_LAST_GOOD: &str = "desktop.rescue.restore_last_good";
pub const RESCUE_RESUME_SHELL: &str = "desktop.rescue.resume_shell";

pub mod scope {
    pub const AGENT_INTERACT: &str = "agent.interact";
    pub const AGENT_READ: &str = "agent.sessions.read";
    pub const AGENT_WRITE: &str = "agent.sessions.write";
    pub const AGENT_MANAGE: &str = "agent.settings.manage";
    /// Acquiring private context (a file, the clipboard, the screen) at the
    /// person's explicit request.
    pub const CONTEXT: &str = "desktop.context";
    /// Submitting and cancelling trusted background jobs (G2-CORE-05).
    pub const JOBS_RUN: &str = "desktop.jobs.run";
    pub const READ: &str = "desktop.read";
    pub const CONFIG: &str = "desktop.config";
    /// Deleting a saved Profile: the one Profile operation that cannot be
    /// undone, so the Agent asks every time unless the person granted it.
    pub const PROFILES_DELETE: &str = "profiles.delete";
    pub const WINDOWS_READ: &str = "desktop.windows.read";
    pub const WINDOWS_CONTROL: &str = "desktop.windows.control";
    pub const RESCUE: &str = "desktop.rescue";
    pub const PLUGINS_MANAGE: &str = "plugins.manage";
    pub const PLUGINS_DEVELOP: &str = "plugins.develop";
    pub const PLUGINS_DATA: &str = "plugins.data";
    pub const PERMISSIONS_MANAGE: &str = "permissions.manage";
    pub const SESSION_POWER: &str = "session.power";
    pub const SESSION_LOCK: &str = "session.lock";
    pub const NOTIFICATIONS_READ: &str = "notifications.read";
    pub const TASKS_READ: &str = "tasks.read";
    pub const TASKS_WRITE: &str = "tasks.write";
    pub const APPS_LAUNCH: &str = "apps.launch";
    pub const CORE: &str = "core";
    pub const NETWORK: &str = "network";
    pub const PROCESS_EXEC: &str = "process.exec";
    pub const CLIPBOARD: &str = "clipboard";
    pub const SCREENSHOT: &str = "screenshot";
    /// `files:<grant_id>`; the prefix alone names the category.
    pub const FILES_PREFIX: &str = "files:";

    pub const ALL: &[&str] = &[
        AGENT_INTERACT,
        AGENT_READ,
        AGENT_WRITE,
        AGENT_MANAGE,
        CONTEXT,
        JOBS_RUN,
        READ,
        CONFIG,
        PROFILES_DELETE,
        WINDOWS_READ,
        WINDOWS_CONTROL,
        RESCUE,
        PLUGINS_MANAGE,
        PLUGINS_DEVELOP,
        PLUGINS_DATA,
        PERMISSIONS_MANAGE,
        SESSION_POWER,
        SESSION_LOCK,
        NOTIFICATIONS_READ,
        TASKS_READ,
        TASKS_WRITE,
        APPS_LAUNCH,
        CORE,
        NETWORK,
        PROCESS_EXEC,
        CLIPBOARD,
        SCREENSHOT,
    ];

    pub fn is_known(scope: &str) -> bool {
        ALL.contains(&scope)
            || scope
                .strip_prefix(FILES_PREFIX)
                .is_some_and(|rest| !rest.is_empty())
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Provider {
    Core,
    Compositor,
    System,
    /// Provided by the hostd entry bound to this slot, under a lease.
    Hostd(&'static str),
}

impl Provider {
    pub fn label(self) -> &'static str {
        match self {
            Self::Core => "core",
            Self::Compositor => "compositor-adapter",
            Self::System => "system",
            Self::Hostd(_) => "hostd",
        }
    }
}

/// Error sets. `permission_denied` is part of every set from 0.2 on, and
/// `preflight_rejected` of every capability that runs a ChangeSet.
const READ_ERRORS: &[ErrorName] = &[
    ErrorName::Unsupported,
    ErrorName::InvalidParams,
    ErrorName::NotFound,
    ErrorName::PermissionDenied,
    ErrorName::Timeout,
    ErrorName::Cancelled,
    ErrorName::Unavailable,
    ErrorName::ProtocolVersionUnsupported,
    ErrorName::IdentityRejected,
    ErrorName::Internal,
];

const WRITE_ERRORS: &[ErrorName] = &[
    ErrorName::Unsupported,
    ErrorName::InvalidParams,
    ErrorName::NotFound,
    ErrorName::PermissionDenied,
    ErrorName::Timeout,
    ErrorName::Cancelled,
    ErrorName::Conflict,
    ErrorName::Unavailable,
    ErrorName::ProtocolVersionUnsupported,
    ErrorName::IdentityRejected,
    ErrorName::Internal,
];

const CHANGE_ERRORS: &[ErrorName] = &[
    ErrorName::Unsupported,
    ErrorName::InvalidParams,
    ErrorName::NotFound,
    ErrorName::PermissionDenied,
    ErrorName::Timeout,
    ErrorName::Cancelled,
    ErrorName::Conflict,
    ErrorName::Unavailable,
    ErrorName::ProtocolVersionUnsupported,
    ErrorName::IdentityRejected,
    ErrorName::PreflightRejected,
    ErrorName::Internal,
];

fn schema<T: JsonSchema>() -> Value {
    serde_json::to_value(schemars::schema_for!(T)).expect("schema serializes")
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Kind {
    Read,
    Write,
    Change,
}

struct Definition {
    capability_id: &'static str,
    input_schema: fn() -> Value,
    output_schema: fn() -> Value,
    kind: Kind,
    cancellable: bool,
    idempotency: Idempotency,
    readback: Option<&'static str>,
    claimable: bool,
    matrix_row: Option<&'static str>,
    provider: Provider,
    scopes: &'static [&'static str],
    timeout: Option<Timeout>,
}

fn def(
    capability_id: &'static str,
    input_schema: fn() -> Value,
    output_schema: fn() -> Value,
    scopes: &'static [&'static str],
) -> Definition {
    Definition {
        capability_id,
        input_schema,
        output_schema,
        kind: Kind::Read,
        cancellable: false,
        idempotency: Idempotency::None,
        readback: None,
        claimable: false,
        matrix_row: None,
        provider: Provider::Core,
        scopes,
        timeout: None,
    }
}

impl Definition {
    fn write(mut self, idempotency: Idempotency, readback: &'static str, claimable: bool) -> Self {
        self.kind = Kind::Write;
        self.idempotency = idempotency;
        self.readback = Some(readback);
        self.claimable = claimable;
        self
    }

    /// Runs a ChangeSet: preflight errors are possible and success is decided
    /// by readback of the change record.
    fn change(mut self, idempotency: Idempotency, readback: &'static str) -> Self {
        self.kind = Kind::Change;
        self.idempotency = idempotency;
        self.readback = Some(readback);
        self.claimable = true;
        self.timeout = Some(Timeout {
            default_ms: 15_000,
            max_ms: 30_000,
        });
        self
    }

    fn compositor(mut self, row: &'static str) -> Self {
        self.matrix_row = Some(row);
        self.provider = Provider::Compositor;
        self
    }

    fn system(mut self) -> Self {
        self.provider = Provider::System;
        self
    }

    fn hostd(mut self, slot: &'static str) -> Self {
        self.provider = Provider::Hostd(slot);
        self
    }

    fn cancellable(mut self) -> Self {
        self.cancellable = true;
        self
    }

    fn timeout(mut self, default_ms: u64, max_ms: u64) -> Self {
        self.timeout = Some(Timeout { default_ms, max_ms });
        self
    }
}

use scope as s;

fn definitions() -> Vec<Definition> {
    use Idempotency::{KeyBased, Natural};
    let mut definitions = vec![
        // ---- G0 -------------------------------------------------------------
        def(
            CAPABILITIES_LIST,
            schema::<Empty>,
            schema::<CapabilitiesListOutput>,
            &[s::READ],
        ),
        def(
            OUTPUTS_LIST,
            schema::<Empty>,
            schema::<OutputsListOutput>,
            &[s::WINDOWS_READ],
        )
        .compositor("C-06"),
        def(
            WORKSPACES_LIST,
            schema::<Empty>,
            schema::<WorkspacesListOutput>,
            &[s::WINDOWS_READ],
        )
        .compositor("C-05"),
        def(
            WORKSPACES_GET,
            schema::<WorkspaceIdInput>,
            schema::<Workspace>,
            &[s::WINDOWS_READ],
        )
        .compositor("C-05"),
        def(
            WORKSPACES_ACTIVATE,
            schema::<WorkspaceIdInput>,
            schema::<Workspace>,
            &[s::WINDOWS_CONTROL],
        )
        .write(Natural, WORKSPACES_GET, true)
        .compositor("C-05"),
        def(
            WINDOWS_LIST,
            schema::<Empty>,
            schema::<WindowsListOutput>,
            &[s::WINDOWS_READ],
        )
        .compositor("C-02"),
        def(
            WINDOWS_GET,
            schema::<WindowIdInput>,
            schema::<Window>,
            &[s::WINDOWS_READ],
        )
        .compositor("C-02"),
        def(
            WINDOWS_FOCUS,
            schema::<WindowIdInput>,
            schema::<Window>,
            &[s::WINDOWS_CONTROL],
        )
        .write(Natural, WINDOWS_GET, true)
        .compositor("C-03"),
        def(
            WINDOWS_MOVE,
            schema::<WindowMoveInput>,
            schema::<Window>,
            &[s::WINDOWS_CONTROL],
        )
        .write(Natural, WINDOWS_GET, true)
        .compositor("C-04"),
        def(
            WINDOWS_RESIZE,
            schema::<WindowResizeInput>,
            schema::<Window>,
            &[s::WINDOWS_CONTROL],
        )
        .write(Natural, WINDOWS_GET, true)
        .compositor("C-04"),
        def(
            WINDOWS_SET_STATE,
            schema::<WindowSetStateInput>,
            schema::<Window>,
            &[s::WINDOWS_CONTROL],
        )
        .write(Natural, WINDOWS_GET, true)
        .compositor("C-03"),
        // Delivery is observable, completion is not: the application may
        // refuse to close, so this capability never claims success.
        def(
            WINDOWS_CLOSE_REQUEST,
            schema::<WindowIdInput>,
            schema::<CloseRequestOutput>,
            &[s::WINDOWS_CONTROL],
        )
        .write(KeyBased, WINDOWS_LIST, false)
        .compositor("C-03"),
        def(
            EVENTS_SUBSCRIBE,
            schema::<EventsSubscribeInput>,
            schema::<EventsSubscribeOutput>,
            &[s::READ],
        )
        .cancellable(),
        // ---- profiles ---------------------------------------------------------
        def(
            PROFILES_LIST,
            schema::<ProfilesListInput>,
            schema::<ProfilesListOutput>,
            &[s::READ],
        ),
        def(
            PROFILES_GET,
            schema::<ProfilesGetInput>,
            schema::<ProfilesGetOutput>,
            &[s::READ],
        ),
        def(
            PROFILES_CREATE,
            schema::<ProfilesCreateInput>,
            schema::<ProfileSummary>,
            &[s::CONFIG],
        )
        .write(KeyBased, PROFILES_GET, true),
        def(
            PROFILES_DUPLICATE,
            schema::<ProfilesDuplicateInput>,
            schema::<ProfileSummary>,
            &[s::CONFIG],
        )
        .write(KeyBased, PROFILES_GET, true),
        def(
            PROFILES_RENAME,
            schema::<ProfilesRenameInput>,
            schema::<ProfileSummary>,
            &[s::CONFIG],
        )
        .write(Natural, PROFILES_GET, true),
        def(
            PROFILES_DELETE,
            schema::<ProfileIdInput>,
            schema::<ProfileSummary>,
            &[s::CONFIG, s::PROFILES_DELETE],
        )
        .write(Natural, PROFILES_LIST, true),
        def(
            PROFILES_DIFF,
            schema::<ProfilesDiffInput>,
            schema::<ProfilesDiffOutput>,
            &[s::READ],
        ),
        def(
            PROFILES_EXPORT,
            schema::<ProfileIdInput>,
            schema::<ProfilesExportOutput>,
            &[s::READ],
        ),
        def(
            PROFILES_IMPORT_VALIDATE,
            schema::<ProfilesImportValidateInput>,
            schema::<ProfilesImportValidateOutput>,
            &[s::READ],
        ),
        def(
            PROFILES_IMPORT,
            schema::<ProfilesImportInput>,
            schema::<ProfileSummary>,
            &[s::CONFIG],
        )
        .write(KeyBased, PROFILES_GET, true),
        // ---- changes ----------------------------------------------------------
        def(
            CHANGES_PROPOSE,
            schema::<ChangesProposeInput>,
            schema::<ChangeRecord>,
            &[s::CONFIG],
        )
        .change(KeyBased, CHANGES_GET),
        def(
            CHANGES_GET,
            schema::<ChangesGetInput>,
            schema::<ChangeRecord>,
            &[s::READ],
        ),
        def(
            CHANGES_LIST,
            schema::<ChangesListInput>,
            schema::<ChangesListOutput>,
            &[s::READ],
        ),
        def(
            CHANGES_CANCEL,
            schema::<ChangeIdInput>,
            schema::<ChangeRecord>,
            &[s::CONFIG],
        )
        .write(Natural, CHANGES_GET, true),
        def(
            CHANGES_UNDO,
            schema::<ChangeIdInput>,
            schema::<ChangeRecord>,
            &[s::CONFIG],
        )
        .change(KeyBased, CHANGES_GET),
        def(
            CHANGES_CONFIRM,
            schema::<ChangeIdInput>,
            schema::<ChangeRecord>,
            &[s::CONFIG],
        )
        .write(Natural, CHANGES_GET, true),
        // ---- plugins ----------------------------------------------------------
        def(
            PLUGINS_LIST,
            schema::<PluginsListInput>,
            schema::<PluginsListOutput>,
            &[s::READ],
        ),
        def(
            PLUGINS_GET,
            schema::<PluginsGetInput>,
            schema::<PluginsGetOutput>,
            &[s::READ],
        ),
        def(
            PLUGINS_INSPECT,
            schema::<PluginsInspectInput>,
            schema::<PluginsInspectOutput>,
            &[s::PLUGINS_MANAGE],
        )
        .timeout(10_000, 30_000),
        def(
            PLUGINS_INSTALL,
            schema::<PluginsInstallInput>,
            schema::<Job>,
            &[s::PLUGINS_MANAGE],
        )
        .write(KeyBased, PLUGINS_GET, true)
        .timeout(30_000, 120_000),
        def(
            PLUGINS_REMOVE,
            schema::<PluginsRemoveInput>,
            schema::<PluginsRemoveOutput>,
            &[s::PLUGINS_MANAGE],
        )
        .write(Natural, PLUGINS_LIST, true),
        def(
            PLUGINS_DIAGNOSTICS,
            schema::<PluginsDiagnosticsInput>,
            schema::<PluginsDiagnosticsOutput>,
            &[s::READ],
        ),
        // ---- permissions ------------------------------------------------------
        def(
            PERMISSIONS_LIST,
            schema::<PermissionsListInput>,
            schema::<PermissionsListOutput>,
            &[s::READ],
        ),
        def(
            PERMISSIONS_CHECK,
            schema::<PermissionsCheckInput>,
            schema::<PermissionsCheckOutput>,
            &[s::READ],
        ),
        def(
            PERMISSIONS_GRANT,
            schema::<PermissionsGrantInput>,
            schema::<Grant>,
            &[s::PERMISSIONS_MANAGE],
        )
        .write(KeyBased, PERMISSIONS_LIST, true),
        def(
            PERMISSIONS_REVOKE,
            schema::<GrantIdInput>,
            schema::<Grant>,
            &[s::PERMISSIONS_MANAGE],
        )
        .write(Natural, PERMISSIONS_LIST, true),
        // ---- appearance, panels, layout, shortcuts, commands ------------------
        def(
            APPEARANCE_GET,
            schema::<AppearanceGetInput>,
            schema::<AppearanceGetOutput>,
            &[s::READ],
        ),
        def(
            APPEARANCE_SET,
            schema::<AppearanceSetInput>,
            schema::<ChangeRecord>,
            &[s::CONFIG],
        )
        .change(KeyBased, APPEARANCE_GET),
        def(
            PANELS_LIST,
            schema::<Empty>,
            schema::<PanelsListOutput>,
            &[s::READ],
        ),
        def(
            LAYOUT_GET,
            schema::<Empty>,
            schema::<LayoutGetOutput>,
            &[s::READ],
        ),
        def(
            SHORTCUTS_LIST,
            schema::<Empty>,
            schema::<ShortcutsListOutput>,
            &[s::READ],
        ),
        def(
            COMMANDS_LIST,
            schema::<Empty>,
            schema::<CommandsListOutput>,
            &[s::READ],
        ),
        def(
            COMMANDS_INVOKE,
            schema::<CommandsInvokeInput>,
            schema::<CommandsInvokeOutput>,
            &[s::CONFIG],
        )
        .write(KeyBased, COMMANDS_LIST, false),
        // ---- launcher (ditto-system) ------------------------------------------
        def(
            LAUNCHER_SEARCH,
            schema::<LauncherSearchInput>,
            schema::<LauncherAppsOutput>,
            &[s::READ],
        )
        .system(),
        def(
            LAUNCHER_LIST_APPS,
            schema::<LauncherListInput>,
            schema::<LauncherAppsOutput>,
            &[s::READ],
        )
        .system(),
        // Starting a program is observable, a window appearing is not.
        def(
            LAUNCHER_LAUNCH,
            schema::<LauncherLaunchInput>,
            schema::<LauncherLaunchOutput>,
            &[s::APPS_LAUNCH],
        )
        .write(KeyBased, WINDOWS_LIST, false)
        .system(),
        // ---- notifications ----------------------------------------------------
        def(
            NOTIFICATIONS_LIST,
            schema::<NotificationsListInput>,
            schema::<NotificationsListOutput>,
            &[s::NOTIFICATIONS_READ],
        )
        .system(),
        def(
            NOTIFICATIONS_DISMISS,
            schema::<NotificationIdInput>,
            schema::<NotificationsDismissOutput>,
            &[s::NOTIFICATIONS_READ],
        )
        .write(Natural, NOTIFICATIONS_LIST, true)
        .system(),
        def(
            NOTIFICATIONS_POLICY_STATUS,
            schema::<Empty>,
            schema::<PolicyStatusOutput>,
            &[s::READ],
        ),
        def(
            NOTIFICATIONS_POLICY_DECIDE,
            schema::<PolicyDecideInput>,
            schema::<PolicyDecideOutput>,
            &[s::CORE],
        )
        .hostd("svc.notification_policy")
        .timeout(50, 200),
        def(
            NOTIFICATIONS_POLICY_GET,
            schema::<Empty>,
            schema::<PolicyGetOutput>,
            &[s::NOTIFICATIONS_READ],
        )
        .hostd("svc.notification_policy"),
        // ---- session (logind) -------------------------------------------------
        def(
            SESSION_STATE,
            schema::<Empty>,
            schema::<SessionState>,
            &[s::READ],
        )
        .system(),
        def(
            SESSION_LOCK,
            schema::<Empty>,
            schema::<SessionActionOutput>,
            &[s::SESSION_LOCK],
        )
        .write(Natural, SESSION_STATE, true)
        .system(),
        def(
            SESSION_LOGOUT,
            schema::<Empty>,
            schema::<SessionActionOutput>,
            &[s::SESSION_POWER],
        )
        .write(KeyBased, SESSION_STATE, false)
        .system(),
        def(
            SESSION_SUSPEND,
            schema::<Empty>,
            schema::<SessionActionOutput>,
            &[s::SESSION_POWER],
        )
        .write(KeyBased, SESSION_STATE, false)
        .system(),
        def(
            SESSION_POWEROFF,
            schema::<Empty>,
            schema::<SessionActionOutput>,
            &[s::SESSION_POWER],
        )
        .write(KeyBased, SESSION_STATE, false)
        .system(),
        // ---- jobs -------------------------------------------------------------
        def(JOBS_GET, schema::<JobIdInput>, schema::<Job>, &[s::READ]),
        def(
            JOBS_LIST,
            schema::<Empty>,
            schema::<JobsListOutput>,
            &[s::READ],
        ),
        def(
            JOBS_CANCEL,
            schema::<JobIdInput>,
            schema::<Job>,
            &[s::JOBS_RUN],
        )
        .write(Natural, JOBS_GET, true),
        def(
            JOBS_SUBMIT,
            schema::<JobsSubmitInput>,
            schema::<Job>,
            &[s::JOBS_RUN],
        )
        .write(KeyBased, JOBS_GET, true),
        // ---- tasks (svc.tasks) ------------------------------------------------
        def(
            TASKS_LIST,
            schema::<TasksListInput>,
            schema::<TasksListOutput>,
            &[s::TASKS_READ],
        )
        .hostd("svc.tasks"),
        def(
            TASKS_ADD,
            schema::<TasksAddInput>,
            schema::<Task>,
            &[s::TASKS_WRITE],
        )
        .write(KeyBased, TASKS_LIST, true)
        .hostd("svc.tasks"),
        def(
            TASKS_COMPLETE,
            schema::<TasksCompleteInput>,
            schema::<Task>,
            &[s::TASKS_WRITE],
        )
        .write(Natural, TASKS_LIST, true)
        .hostd("svc.tasks"),
        // Core runs the subscription (one broker, one `seq`); the snapshot
        // comes from the provider, so it is unavailable without one.
        def(
            TASKS_SUBSCRIBE,
            schema::<Empty>,
            schema::<TasksSubscribeOutput>,
            &[s::TASKS_READ],
        )
        .hostd("svc.tasks")
        .cancellable(),
        // ---- rescue -----------------------------------------------------------
        def(
            RESCUE_STATUS,
            schema::<Empty>,
            schema::<RescueStatusOutput>,
            &[s::READ],
        ),
        def(
            RESCUE_DISABLE,
            schema::<RescueDisableInput>,
            schema::<ChangeRecord>,
            &[s::RESCUE],
        )
        .change(KeyBased, CHANGES_GET),
        def(
            RESCUE_RESTORE_LAST_GOOD,
            schema::<RescueRestoreInput>,
            schema::<ChangeRecord>,
            &[s::RESCUE],
        )
        .change(KeyBased, CHANGES_GET),
        // Leave the rescue UI for the normal Shell: what it reads back is
        // the new Shell's connection.
        def(
            RESCUE_RESUME_SHELL,
            schema::<Empty>,
            schema::<RescueResumeShellOutput>,
            &[s::RESCUE],
        )
        .write(Natural, RESCUE_STATUS, false)
        .timeout(15_000, 30_000),
    ];
    definitions.extend(agent_definitions());
    definitions.extend(generation_definitions());
    definitions
}

fn generation_definitions() -> Vec<Definition> {
    use crate::generation::*;
    use Idempotency::{KeyBased, Natural};
    vec![
        def(
            DEVELOPMENT_CREATE,
            schema::<GenerateInput>,
            schema::<GeneratedArtifact>,
            &[s::PLUGINS_DEVELOP],
        )
        .write(KeyBased, DEVELOPMENT_GET, true),
        def(
            DEVELOPMENT_GET,
            schema::<ArtifactInput>,
            schema::<GeneratedArtifact>,
            &[s::READ],
        ),
        def(
            DEVELOPMENT_LIST,
            schema::<Empty>,
            schema::<ArtifactsOutput>,
            &[s::READ],
        ),
        def(
            DEVELOPMENT_VALIDATE,
            schema::<GenerationJobInput>,
            schema::<Job>,
            &[s::PLUGINS_DEVELOP],
        )
        .write(KeyBased, JOBS_GET, true),
        def(
            DEVELOPMENT_PREVIEW,
            schema::<GenerationJobInput>,
            schema::<Job>,
            &[s::PLUGINS_DEVELOP],
        )
        .write(KeyBased, JOBS_GET, true),
        def(
            DEVELOPMENT_PUBLISH,
            schema::<ArtifactInput>,
            schema::<GeneratedArtifact>,
            &[s::PLUGINS_DEVELOP],
        )
        .write(Natural, DEVELOPMENT_GET, true),
        def(
            DEVELOPMENT_ACTIVATE,
            schema::<GenerationActivateInput>,
            schema::<crate::change::ChangeRecord>,
            &[s::PLUGINS_DEVELOP, s::CONFIG, s::PLUGINS_DATA],
        )
        .change(KeyBased, CHANGES_GET),
        def(
            DEVELOPMENT_DATA_GET,
            schema::<ArtifactInput>,
            schema::<GeneratedData>,
            &[s::PLUGINS_DATA],
        ),
        def(
            DEVELOPMENT_DATA_WRITE,
            schema::<GeneratedDataInput>,
            schema::<GeneratedData>,
            &[s::PLUGINS_DATA],
        )
        .write(Natural, DEVELOPMENT_DATA_GET, true),
    ]
}

fn agent_definitions() -> Vec<Definition> {
    use crate::agent::*;
    use Idempotency::{KeyBased, Natural};
    vec![
        def(
            "desktop.profiles.upgrade",
            schema::<ProfileUpgradeInput>,
            schema::<ChangeRecord>,
            &[s::CONFIG],
        )
        .change(KeyBased, "desktop.changes.get")
        .cancellable(),
        def(
            "agent.sessions.create",
            schema::<SessionCreateInput>,
            schema::<Conversation>,
            &[s::AGENT_INTERACT],
        )
        .write(KeyBased, "agent.sessions.stat", false),
        def(
            "agent.sessions.list",
            schema::<Empty>,
            schema::<SessionsListOutput>,
            &[s::AGENT_READ],
        ),
        def(
            "agent.sessions.stat",
            schema::<SessionIdInput>,
            schema::<Conversation>,
            &[s::AGENT_READ],
        ),
        def(
            "agent.sessions.read",
            schema::<SessionReadInput>,
            schema::<SessionReadOutput>,
            &[s::AGENT_READ],
        ),
        def(
            "agent.sessions.open",
            schema::<SessionIdInput>,
            schema::<SessionOpenOutput>,
            &[s::AGENT_WRITE],
        )
        .write(Natural, "agent.sessions.stat", false),
        def(
            "agent.sessions.append",
            schema::<SessionAppendInput>,
            schema::<Conversation>,
            &[s::AGENT_WRITE],
        )
        .write(KeyBased, "agent.sessions.stat", false),
        def(
            "agent.sessions.flush",
            schema::<SessionWriteInput>,
            schema::<Conversation>,
            &[s::AGENT_WRITE],
        )
        .write(Natural, "agent.sessions.stat", false),
        def(
            "agent.sessions.close",
            schema::<SessionWriteInput>,
            schema::<Conversation>,
            &[s::AGENT_WRITE],
        )
        .write(Natural, "agent.sessions.stat", false),
        def(
            "agent.sessions.delete",
            schema::<SessionIdInput>,
            schema::<SessionDeleteOutput>,
            &[s::AGENT_MANAGE],
        )
        .write(Natural, "agent.sessions.list", false),
        def(
            "agent.settings.describe",
            schema::<Empty>,
            schema::<AgentPreferences>,
            &[s::AGENT_READ],
        ),
        def(
            "agent.settings.patch",
            schema::<PreferencesPatchInput>,
            schema::<AgentPreferences>,
            &[s::AGENT_MANAGE],
        )
        .write(Natural, "agent.settings.describe", false),
        def(
            "agent.turns.submit",
            schema::<TurnSubmitInput>,
            schema::<Turn>,
            &[s::AGENT_INTERACT],
        )
        .write(KeyBased, "agent.turns.get", false),
        def(
            "agent.turns.get",
            schema::<TurnIdInput>,
            schema::<Turn>,
            &[s::AGENT_READ],
        ),
        def(
            "agent.turns.trace",
            schema::<TurnIdInput>,
            schema::<TurnTraceOutput>,
            &[s::AGENT_READ],
        ),
        def(
            "agent.turns.cancel",
            schema::<TurnIdInput>,
            schema::<Turn>,
            &[s::AGENT_INTERACT],
        )
        .write(Natural, "agent.turns.get", false),
        def(
            "agent.turns.claim",
            schema::<TurnIdInput>,
            schema::<TurnClaimOutput>,
            &[s::AGENT_WRITE],
        )
        .write(Natural, "agent.turns.get", false),
        def(
            "agent.turns.complete",
            schema::<TurnCompleteInput>,
            schema::<Turn>,
            &[s::AGENT_WRITE],
        )
        .write(Natural, "agent.turns.get", false),
        def(
            "agent.tools.intent",
            schema::<ToolIntentInput>,
            schema::<ToolIntent>,
            &[s::AGENT_WRITE],
        )
        .write(KeyBased, "agent.turns.get", false),
        def(
            "agent.tools.abandon",
            schema::<ToolAbandonInput>,
            schema::<Empty>,
            &[s::AGENT_WRITE],
        )
        .write(Natural, "agent.turns.get", false),
        def(
            "agent.runtime.get",
            schema::<Empty>,
            schema::<AgentRuntimeStatus>,
            &[s::AGENT_READ],
        ),
        def(
            "agent.runtime.ensure",
            schema::<Empty>,
            schema::<AgentRuntimeStatus>,
            &[s::AGENT_INTERACT],
        )
        .write(Natural, "agent.runtime.get", false)
        .timeout(2_000, 10_000),
        def(
            "agent.runtime.ready",
            schema::<AgentReadyInput>,
            schema::<AgentRuntimeStatus>,
            &[s::AGENT_WRITE],
        )
        .write(Natural, "agent.runtime.get", false),
        def(
            "agent.runtime.stop",
            schema::<Empty>,
            schema::<AgentRuntimeStatus>,
            &[s::AGENT_MANAGE],
        )
        .write(Natural, "agent.runtime.get", true),
        def(
            "agent.providers.status",
            schema::<ProviderLoginInput>,
            schema::<ProviderStatus>,
            &[s::AGENT_MANAGE],
        )
        .cancellable()
        .timeout(10_000, 30_000),
        def(
            "agent.providers.login",
            schema::<ProviderLoginInput>,
            schema::<ProviderLoginOutput>,
            &[s::AGENT_MANAGE],
        )
        .write(Natural, "agent.providers.status", true)
        .timeout(10_000, 30_000),
        def(
            "agent.providers.cancel_login",
            schema::<ProviderCancelLoginInput>,
            schema::<ProviderActionOutput>,
            &[s::AGENT_MANAGE],
        )
        .write(Natural, "agent.providers.status", false),
        def(
            "agent.providers.logout",
            schema::<ProviderLoginInput>,
            schema::<ProviderActionOutput>,
            &[s::AGENT_MANAGE],
        )
        .write(Natural, "agent.providers.status", true),
        def(
            "desktop.approvals.request",
            schema::<ApprovalRequestInput>,
            schema::<Approval>,
            &[s::AGENT_INTERACT],
        )
        .write(KeyBased, "desktop.approvals.get", false),
        def(
            "desktop.approvals.get",
            schema::<ApprovalIdInput>,
            schema::<Approval>,
            &[s::AGENT_READ],
        ),
        def(
            "agent.turns.stream",
            schema::<TurnStreamInput>,
            schema::<Empty>,
            &[s::AGENT_WRITE],
        ),
        def(
            "agent.credentials.create",
            schema::<CredentialCreateInput>,
            schema::<CredentialStatus>,
            &[s::AGENT_MANAGE],
        )
        .write(KeyBased, "agent.credentials.status", false),
        def(
            "agent.credentials.status",
            schema::<CredentialRefInput>,
            schema::<CredentialStatus>,
            &[s::AGENT_MANAGE],
        ),
        def(
            "agent.credentials.delete",
            schema::<CredentialRefInput>,
            schema::<CredentialStatus>,
            &[s::AGENT_MANAGE],
        )
        .write(Natural, "agent.credentials.status", false),
        def(
            "agent.credentials.resolve",
            schema::<CredentialResolveInput>,
            schema::<CredentialResolveOutput>,
            &[s::AGENT_WRITE],
        ),
        def(
            "desktop.context.acquire",
            schema::<ContextAcquireInput>,
            schema::<ContextReference>,
            &[s::CONTEXT],
        )
        .timeout(5_000, 30_000),
        def(
            "desktop.context.preview",
            schema::<ContextIdInput>,
            schema::<ContextPreviewOutput>,
            &[s::CONTEXT],
        ),
        def(
            "desktop.context.release",
            schema::<ContextIdInput>,
            schema::<Empty>,
            &[s::CONTEXT],
        ),
        def(
            "desktop.approvals.list",
            schema::<Empty>,
            schema::<ApprovalsListOutput>,
            &[s::AGENT_READ],
        ),
        def(
            "desktop.approvals.decide",
            schema::<ApprovalDecideInput>,
            schema::<Approval>,
            &[s::PERMISSIONS_MANAGE],
        )
        .write(KeyBased, "desktop.approvals.get", false),
    ]
}

/// Timeouts are part of the contract: a capability with no upper bound is not
/// exposed across processes.
fn timeout_for(definition: &Definition) -> Timeout {
    if let Some(timeout) = &definition.timeout {
        return timeout.clone();
    }
    if definition.cancellable {
        Timeout {
            default_ms: 5_000,
            max_ms: 30_000,
        }
    } else {
        Timeout {
            default_ms: 2_000,
            max_ms: 5_000,
        }
    }
}

/// The runtime-relevant part of a descriptor, without the schemas. Core routes
/// on this so request handling never rebuilds every JSON Schema.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CapabilityContract {
    pub capability_id: &'static str,
    pub cancellable: bool,
    pub timeout: Timeout,
    pub readback: Option<&'static str>,
    pub claimable: bool,
    pub matrix_row: Option<&'static str>,
    pub provider: Provider,
    pub scopes: &'static [&'static str],
    pub writes: bool,
    pub runs_change: bool,
}

pub fn contracts() -> Vec<CapabilityContract> {
    definitions()
        .into_iter()
        .map(|definition| CapabilityContract {
            capability_id: definition.capability_id,
            cancellable: definition.cancellable,
            timeout: timeout_for(&definition),
            readback: definition.readback,
            claimable: definition.claimable,
            matrix_row: definition.matrix_row,
            provider: definition.provider,
            scopes: definition.scopes,
            writes: definition.kind != Kind::Read,
            runs_change: definition.kind == Kind::Change,
        })
        .collect()
}

pub fn contract(capability_id: &str) -> Option<CapabilityContract> {
    static CONTRACTS: std::sync::OnceLock<Vec<CapabilityContract>> = std::sync::OnceLock::new();
    CONTRACTS
        .get_or_init(contracts)
        .iter()
        .find(|contract| contract.capability_id == capability_id)
        .cloned()
}

fn descriptor(definition: Definition, availability: Availability) -> CapabilityDescriptor {
    let timeout = timeout_for(&definition);
    CapabilityDescriptor {
        capability_id: definition.capability_id.into(),
        version: "1.0.0".into(),
        input_schema: (definition.input_schema)(),
        output_schema: (definition.output_schema)(),
        errors: match definition.kind {
            Kind::Read => READ_ERRORS.to_vec(),
            Kind::Write => WRITE_ERRORS.to_vec(),
            Kind::Change => CHANGE_ERRORS.to_vec(),
        },
        resource_scope: definition
            .scopes
            .iter()
            .map(|scope| scope.to_string())
            .collect(),
        cancellable: definition.cancellable,
        idempotency: definition.idempotency,
        timeout_ms: timeout,
        readback: definition.readback.map(Into::into),
        claimable: definition.claimable,
        provider: definition.provider.label().into(),
        availability,
    }
}

fn exported_availability(definition: &Definition) -> Availability {
    match definition.provider {
        Provider::Core
            if definition.capability_id.starts_with("agent.providers.")
                || definition.capability_id == "agent.runtime.ensure" =>
        {
            Availability::ResolvedAtRuntime {
                matrix_row: None,
                slot: None,
            }
        }
        Provider::Core => Availability::Always,
        Provider::Compositor => Availability::ResolvedAtRuntime {
            matrix_row: definition.matrix_row.map(Into::into),
            slot: None,
        },
        Provider::System => Availability::ResolvedAtRuntime {
            matrix_row: None,
            slot: None,
        },
        Provider::Hostd(slot) => Availability::ResolvedAtRuntime {
            matrix_row: None,
            slot: Some(slot.into()),
        },
    }
}

/// The exported contract: every capability with what it depends on.
pub fn catalog() -> CapabilitiesListOutput {
    CapabilitiesListOutput {
        catalog_revision: CATALOG_REVISION,
        capabilities: definitions()
            .into_iter()
            .map(|definition| {
                let availability = exported_availability(&definition);
                descriptor(definition, availability)
            })
            .collect(),
    }
}

/// What Core knows at runtime about one capability's provider.
pub struct Resolved {
    pub availability: Availability,
    /// `hostd:<entry_id>` when a hostd entry currently provides it.
    pub provider_label: Option<String>,
}

/// The served catalog: `resolve` reports what is actually offered, so a
/// consumer learns a capability is unavailable before calling it.
pub fn resolved_catalog(
    resolve: impl Fn(&CapabilityContract) -> Resolved,
) -> CapabilitiesListOutput {
    CapabilitiesListOutput {
        catalog_revision: CATALOG_REVISION,
        capabilities: definitions()
            .into_iter()
            .map(|definition| {
                let contract = CapabilityContract {
                    capability_id: definition.capability_id,
                    cancellable: definition.cancellable,
                    timeout: timeout_for(&definition),
                    readback: definition.readback,
                    claimable: definition.claimable,
                    matrix_row: definition.matrix_row,
                    provider: definition.provider,
                    scopes: definition.scopes,
                    writes: definition.kind != Kind::Read,
                    runs_change: definition.kind == Kind::Change,
                };
                let resolved = resolve(&contract);
                let mut item = descriptor(definition, resolved.availability);
                if let Some(label) = resolved.provider_label {
                    item.provider = label;
                }
                item
            })
            .collect(),
    }
}

/// The D-23 gate: every descriptor has a handler and a consumer, a closed
/// error set containing `unsupported`, a bounded timeout, a readback behind
/// every claim of success, and (0.2) a non-empty, known resource scope.
pub fn validate_catalog(
    descriptors: &[CapabilityDescriptor],
    provider_handlers: &[&str],
    consumers: &[&str],
) -> Result<(), String> {
    let ids: std::collections::HashSet<_> = descriptors
        .iter()
        .map(|item| item.capability_id.as_str())
        .collect();
    if ids.len() != descriptors.len() {
        return Err("duplicate capability_id".into());
    }
    for item in descriptors {
        let id = item.capability_id.as_str();
        if !provider_handlers.contains(&id) {
            return Err(format!("{id}: no registered handler"));
        }
        if !consumers.contains(&id) {
            return Err(format!("{id}: no registered consumer"));
        }
        if !item.errors.contains(&ErrorName::Unsupported) {
            return Err(format!("{id}: unsupported missing from closed error set"));
        }
        if item.timeout_ms.default_ms == 0
            || item.timeout_ms.max_ms == 0
            || item.timeout_ms.default_ms > item.timeout_ms.max_ms
        {
            return Err(format!("{id}: invalid timeout"));
        }
        if item.resource_scope.is_empty() {
            return Err(format!("{id}: resource_scope is empty"));
        }
        if let Some(unknown) = item
            .resource_scope
            .iter()
            .find(|scope| !scope::is_known(scope))
        {
            return Err(format!("{id}: unknown resource scope {unknown}"));
        }
        if let Some(readback) = &item.readback {
            if !ids.contains(readback.as_str()) {
                return Err(format!("{id}: readback {readback} is not registered"));
            }
        } else if item.claimable {
            return Err(format!("{id}: cannot claim success without readback"));
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn all_ids() -> Vec<String> {
        catalog()
            .capabilities
            .iter()
            .map(|item| item.capability_id.clone())
            .collect()
    }

    #[test]
    fn rejects_missing_seam_or_unverifiable_success() {
        let mut entries = catalog().capabilities;
        let ids = all_ids();
        let all: Vec<&str> = ids.iter().map(String::as_str).collect();
        assert!(validate_catalog(&entries, &all, &all).is_ok());
        assert!(validate_catalog(&entries, &[], &all).is_err());
        assert!(validate_catalog(&entries, &all, &[]).is_err());
        let subscribe = entries
            .iter_mut()
            .find(|item| item.capability_id == EVENTS_SUBSCRIBE)
            .expect("subscribe is in the catalog");
        subscribe.claimable = true;
        assert!(validate_catalog(&entries, &all, &all).is_err());
    }

    #[test]
    fn an_empty_or_unknown_scope_fails_the_gate() {
        let ids = all_ids();
        let all: Vec<&str> = ids.iter().map(String::as_str).collect();
        let mut entries = catalog().capabilities;
        entries[0].resource_scope.clear();
        assert!(validate_catalog(&entries, &all, &all)
            .unwrap_err()
            .contains("resource_scope is empty"));
        let mut entries = catalog().capabilities;
        entries[0].resource_scope = vec!["everything".into()];
        assert!(validate_catalog(&entries, &all, &all)
            .unwrap_err()
            .contains("unknown resource scope"));
    }

    #[test]
    fn close_request_and_launch_report_delivery_only() {
        let catalog = catalog();
        for id in [WINDOWS_CLOSE_REQUEST, LAUNCHER_LAUNCH, COMMANDS_INVOKE] {
            let item = catalog
                .capabilities
                .iter()
                .find(|item| item.capability_id == id)
                .expect("in the catalog");
            assert!(!item.claimable, "{id}");
            assert!(item.readback.is_some(), "{id}");
        }
    }

    #[test]
    fn every_config_write_runs_a_changeset_or_is_a_profile_operation() {
        // `desktop.config` writes that change Profile *content* must be
        // ChangeSet wrappers; naming and bookkeeping operations are not.
        let bookkeeping = [
            PROFILES_CREATE,
            PROFILES_DUPLICATE,
            PROFILES_RENAME,
            PROFILES_DELETE,
            PROFILES_IMPORT,
            CHANGES_CANCEL,
            CHANGES_CONFIRM,
            COMMANDS_INVOKE,
        ];
        for contract in contracts() {
            if contract.writes && contract.scopes.contains(&scope::CONFIG) {
                assert!(
                    contract.runs_change || bookkeeping.contains(&contract.capability_id),
                    "{} writes configuration outside a ChangeSet",
                    contract.capability_id
                );
            }
        }
    }

    #[test]
    fn exported_catalog_defers_runtime_availability() {
        for item in catalog().capabilities {
            match (&item.availability, item.provider.as_str()) {
                (Availability::Always, "core") => {}
                (Availability::ResolvedAtRuntime { .. }, "core")
                    if item.capability_id.starts_with("agent.providers.")
                        || item.capability_id == "agent.runtime.ensure" => {}
                (
                    Availability::ResolvedAtRuntime {
                        matrix_row: Some(_),
                        ..
                    },
                    "compositor-adapter",
                ) => {}
                (Availability::ResolvedAtRuntime { slot: Some(_), .. }, "hostd") => {}
                (Availability::ResolvedAtRuntime { .. }, "system") => {}
                (availability, provider) => panic!(
                    "{} ({provider}) must not claim availability at export time: {availability:?}",
                    item.capability_id
                ),
            }
        }
    }
}
