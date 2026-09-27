//! Rust is the authority for Ditto's wire types. Contract versions are independent
//! of crate versions. A required field or changed meaning needs a new contract
//! version; an optional field does not.

pub mod catalog;
pub mod change;
pub mod host;
pub mod ids;
pub mod jcs;
pub mod manifest;
pub mod participant;
pub mod profile;
pub mod rpc;
pub mod services;

use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

/// 0.2 is not wire-compatible with 0.1: `ResultMeta.revision` split in two,
/// requests flow in both directions, and `preflight_rejected` joined the error
/// set. A 0.1 client is refused at the handshake instead of being guessed at.
pub const PROTOCOL_VERSION: &str = "0.2.0";

/// How a controlled launcher hands a client its one-use token: on an inherited
/// descriptor, so the secret never appears in the client's environment, which
/// any process of the same user can read.
pub const LAUNCHER_TOKEN_FD: i32 = 3;
pub const LAUNCHER_TOKEN_FD_ENV: &str = "DITTO_CORE_TOKEN_FD";
pub const LAUNCHER_SOCKET_ENV: &str = "DITTO_CORE_SOCKET";
pub const LAUNCHER_KIND_ENV: &str = "DITTO_CLIENT_KIND";
pub const LAUNCHER_VERSION_ENV: &str = "DITTO_CLIENT_VERSION";

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Empty {}

/// An opaque identifier valid only for the current compositor session.
#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq, Hash)]
#[serde(transparent)]
pub struct WindowSessionId(pub String);

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct Output {
    pub name: String,
    pub width: u32,
    pub height: u32,
    pub scale: f64,
    pub x: i32,
    pub y: i32,
    pub enabled: bool,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct Workspace {
    pub id: String,
    pub name: String,
    pub active: bool,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct Window {
    pub id: WindowSessionId,
    pub title: String,
    pub app_id: String,
    pub workspace_id: Option<String>,
    pub x: Option<i32>,
    pub y: Option<i32>,
    pub width: Option<u32>,
    pub height: Option<u32>,
    pub focused: bool,
    pub state: WindowState,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum WindowState {
    Normal,
    Minimized,
    Maximized,
    Fullscreen,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct OutputsListOutput {
    pub outputs: Vec<Output>,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct WorkspacesListOutput {
    pub workspaces: Vec<Workspace>,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct WindowsListOutput {
    pub windows: Vec<Window>,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct WorkspaceIdInput {
    pub workspace_id: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct WindowIdInput {
    pub window_id: WindowSessionId,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct WindowMoveInput {
    pub window_id: WindowSessionId,
    pub x: i32,
    pub y: i32,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct WindowResizeInput {
    pub window_id: WindowSessionId,
    pub width: u32,
    pub height: u32,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct WindowSetStateInput {
    pub window_id: WindowSessionId,
    pub state: WindowState,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct CloseRequestOutput {
    /// Accepted means the request reached the compositor. It does not mean the
    /// application closed; observe a window event or read windows.list.
    pub accepted: bool,
    pub operation_id: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct EventsSubscribeInput {
    pub after_seq: Option<u64>,
    /// Absent means `["desktop"]`, the G0 stream. Each topic needs its own
    /// scope, so asking for more than the caller may read is refused whole.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub topics: Option<Vec<EventTopic>>,
}

#[derive(
    Clone, Copy, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq, Hash, PartialOrd, Ord,
)]
#[serde(rename_all = "snake_case")]
pub enum EventTopic {
    Desktop,
    Changes,
    Plugins,
    Notifications,
    Tasks,
    Session,
}

impl EventTopic {
    pub const ALL: [Self; 6] = [
        Self::Desktop,
        Self::Changes,
        Self::Plugins,
        Self::Notifications,
        Self::Tasks,
        Self::Session,
    ];
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct DesktopSnapshot {
    pub outputs: Vec<Output>,
    pub workspaces: Vec<Workspace>,
    pub windows: Vec<Window>,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct EventsSubscribeOutput {
    pub subscription_id: String,
    pub snapshot: DesktopSnapshot,
    pub seq: u64,
    /// Set when the requested `after_seq` had already left the retained window:
    /// the consumer must rebuild from this snapshot instead of continuing.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resynced: Option<bool>,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum DesktopEventPayload {
    WindowUpsert {
        window: Window,
    },
    WindowRemoved {
        window_id: WindowSessionId,
    },
    WorkspaceUpsert {
        workspace: Workspace,
    },
    WorkspaceRemoved {
        workspace_id: String,
    },
    OutputUpsert {
        output: Output,
    },
    OutputRemoved {
        output_name: String,
    },
    ResyncRequired {
        reason: String,
    },
    ProfileChanged {
        profile_id: String,
        head_revision: String,
        active: bool,
    },
    ChangeUpdated {
        change: Box<change::ChangeSummary>,
    },
    CapabilitiesChanged {
        reason: String,
    },
    PanelsChanged {
        panels: Vec<services::PanelStatus>,
    },
    JobsUpdated {
        job: services::Job,
    },
    NotificationPosted {
        notification: services::NotificationItem,
    },
    NotificationClosed {
        id: u32,
        reason: String,
    },
    /// A cross-process event a hostd entry declared in its manifest.
    HostEvent {
        entry_id: String,
        name: String,
        payload: serde_json::Value,
    },
    SessionChanged {
        state: services::SessionState,
    },
}

impl DesktopEventPayload {
    /// Which subscription topic carries this payload. `resync_required` goes
    /// to every subscription regardless of topic.
    pub fn topic(&self) -> Option<EventTopic> {
        Some(match self {
            Self::WindowUpsert { .. }
            | Self::WindowRemoved { .. }
            | Self::WorkspaceUpsert { .. }
            | Self::WorkspaceRemoved { .. }
            | Self::OutputUpsert { .. }
            | Self::OutputRemoved { .. } => EventTopic::Desktop,
            Self::ResyncRequired { .. } => return None,
            Self::ProfileChanged { .. } | Self::ChangeUpdated { .. } => EventTopic::Changes,
            Self::CapabilitiesChanged { .. }
            | Self::PanelsChanged { .. }
            | Self::JobsUpdated { .. } => EventTopic::Plugins,
            Self::NotificationPosted { .. } | Self::NotificationClosed { .. } => {
                EventTopic::Notifications
            }
            Self::HostEvent { name, .. } if name.starts_with("tasks/") => EventTopic::Tasks,
            Self::HostEvent { .. } => EventTopic::Plugins,
            Self::SessionChanged { .. } => EventTopic::Session,
        })
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct DesktopEventNotification {
    pub subscription_id: String,
    /// Position in Core's single event stream, shared by every topic; the
    /// value to pass as `after_seq` when resubscribing.
    pub seq: u64,
    /// The `seq` of the previous event delivered to this subscription (or the
    /// subscription's starting `seq`). A consumer detects a lost event when it
    /// differs from the last `seq` it saw: topics it did not ask for leave
    /// gaps in `seq`, never in this chain.
    pub prev_seq: u64,
    /// The active Profile head when the event was published; `null` before
    /// Core has loaded a Profile. 0.1 called an observation counter `revision`.
    pub profile_revision: Option<String>,
    pub payload: DesktopEventPayload,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct RequestMeta {
    pub protocol_version: String,
    pub operation_id: Option<String>,
    pub deadline_ms: Option<u64>,
    /// Only a hostd connection may, and must, name the entry it calls for.
    /// Core accepts it only for an entry it assigned to that connection.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub on_behalf_of: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct ResultMeta {
    /// Observation sequence of the event stream (the G0 meaning of revision).
    pub observed_seq: u64,
    /// Head revision of the active Profile, `null` before one is loaded.
    pub profile_revision: Option<String>,
    pub readback_verified: bool,
    /// Set when a cancellation arrived for a capability declared
    /// non-cancellable: the request ran to completion and was not cancelled.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub not_cancellable: Option<bool>,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ErrorName {
    Unsupported,
    InvalidParams,
    NotFound,
    PermissionDenied,
    Timeout,
    Cancelled,
    Conflict,
    Unavailable,
    ProtocolVersionUnsupported,
    IdentityRejected,
    PreflightRejected,
    Internal,
}

impl ErrorName {
    pub const ALL: [Self; 12] = [
        Self::Unsupported,
        Self::InvalidParams,
        Self::NotFound,
        Self::PermissionDenied,
        Self::Timeout,
        Self::Cancelled,
        Self::Conflict,
        Self::Unavailable,
        Self::ProtocolVersionUnsupported,
        Self::IdentityRejected,
        Self::PreflightRejected,
        Self::Internal,
    ];

    pub fn code(&self) -> i32 {
        match self {
            Self::Unsupported => -32000,
            Self::InvalidParams => -32001,
            Self::NotFound => -32002,
            Self::PermissionDenied => -32003,
            Self::Timeout => -32004,
            Self::Cancelled => -32005,
            Self::Conflict => -32006,
            Self::Unavailable => -32007,
            Self::ProtocolVersionUnsupported => -32008,
            Self::IdentityRejected => -32009,
            Self::PreflightRejected => -32010,
            Self::Internal => -32099,
        }
    }
}

/// Why a capability or a call is unavailable. Closed: a consumer can show a
/// specific product sentence for every value.
#[derive(Clone, Copy, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq, Hash)]
#[serde(rename_all = "snake_case")]
pub enum UnavailableReason {
    CompositorOffline,
    HostUnavailable,
    HostCrashLoop,
    LeaseExpired,
    NotBound,
    RescueMode,
    Recovering,
    SystemUnavailable,
    ParticipantUnavailable,
    SessionLocked,
    /// The store refused the write for lack of space; nothing changed.
    StorageFull,
    /// The store reported an I/O error; nothing changed.
    StorageError,
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq, Hash)]
#[serde(rename_all = "snake_case")]
pub enum ConflictReason {
    BaseRevisionStale,
    CandidateCannotClaim,
    SingleProviderTaken,
    UndoBlockedByNewerChange,
    ProfileInUse,
    ChangeInProgress,
    ReadbackMismatch,
    AlreadyTerminal,
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq, Hash)]
#[serde(rename_all = "snake_case")]
pub enum PermissionDeniedReason {
    NotGranted,
    PolicyDenied,
    /// No approval responder exists (G1) or it failed: always a refusal.
    ApprovalUnavailable,
}

/// The authorization subject, derived from the launcher binding and, for a
/// hostd connection, from an entry Core assigned to it. Never from a message.
#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq, Hash)]
#[serde(transparent)]
pub struct Subject(pub String);

impl Subject {
    pub const SHELL: &'static str = "shell";
    pub const CLI: &'static str = "cli";
    pub const CLI_RESCUE: &'static str = "cli:rescue";
    pub const RESCUE_UI: &'static str = "rescue_ui";
    pub const AGENT: &'static str = "agent";
    pub const LOCK: &'static str = "lock";
    pub const CORE: &'static str = "core";

    pub fn host(entry_id: &str) -> Self {
        Self(format!("host:{entry_id}"))
    }

    pub fn host_entry(&self) -> Option<&str> {
        self.0.strip_prefix("host:")
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn error_codes_are_distinct_and_round_trip() {
        let mut codes = std::collections::HashSet::new();
        for name in ErrorName::ALL {
            assert!(codes.insert(name.code()));
            let wire = serde_json::to_string(&name).unwrap();
            assert_eq!(serde_json::from_str::<ErrorName>(&wire).unwrap(), name);
        }
    }

    #[test]
    fn session_id_is_wire_string() {
        let id = WindowSessionId("session-1/window-2".into());
        assert_eq!(
            serde_json::to_string(&id).unwrap(),
            "\"session-1/window-2\""
        );
    }
}
