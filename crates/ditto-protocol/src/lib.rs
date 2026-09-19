//! Rust is the authority for Ditto's wire types. Contract versions are independent
//! of crate versions. A required field or changed meaning needs a new contract
//! version; an optional field does not.

pub mod catalog;
pub mod rpc;

use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

pub const PROTOCOL_VERSION: &str = "0.1.0";

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
    WindowUpsert { window: Window },
    WindowRemoved { window_id: WindowSessionId },
    WorkspaceUpsert { workspace: Workspace },
    WorkspaceRemoved { workspace_id: String },
    OutputUpsert { output: Output },
    OutputRemoved { output_name: String },
    ResyncRequired { reason: String },
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct DesktopEventNotification {
    pub subscription_id: String,
    pub seq: u64,
    /// Observation revision; no persistent Profile exists in G0.
    pub revision: u64,
    pub payload: DesktopEventPayload,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct RequestMeta {
    pub protocol_version: String,
    pub operation_id: Option<String>,
    pub deadline_ms: Option<u64>,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct ResultMeta {
    /// Observation sequence, not a persistent Profile revision in G0.
    pub revision: u64,
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
    Internal,
}

impl ErrorName {
    pub const ALL: [Self; 11] = [
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
            Self::Internal => -32099,
        }
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
