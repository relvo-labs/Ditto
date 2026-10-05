use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::ErrorName;

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct RpcRequest {
    pub jsonrpc: String,
    /// Absent on notifications. Ids Core itself issues start with `core-`; a
    /// client may not use that prefix for its own requests.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub id: Option<String>,
    pub method: String,
    pub params: Value,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct RpcResponse {
    pub jsonrpc: String,
    pub id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<RpcError>,
}

impl RpcResponse {
    pub fn ok(id: String, result: Value) -> Self {
        Self {
            jsonrpc: "2.0".into(),
            id,
            result: Some(result),
            error: None,
        }
    }

    pub fn error(id: String, name: ErrorName, message: &str) -> Self {
        Self::error_with(id, name, message, None)
    }

    pub fn error_with(id: String, name: ErrorName, message: &str, data: Option<Value>) -> Self {
        Self {
            jsonrpc: "2.0".into(),
            id,
            result: None,
            error: Some(RpcError {
                code: name.code(),
                name,
                message: message.into(),
                outcome: None,
                data,
            }),
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct RpcError {
    pub code: i32,
    pub name: ErrorName,
    pub message: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub outcome: Option<Outcome>,
    /// Reason codes and translation keys, never product text: `reason` for
    /// `unavailable`, `conflict` and `permission_denied`; `reasons[]` for
    /// `preflight_rejected`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub data: Option<Value>,
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum CoreMode {
    Normal,
    /// No hostd: Cordis-backed capabilities report `rescue_mode`.
    Rescue,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum Outcome {
    Unknown,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct ClientInfo {
    pub kind: String,
    pub version: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct HandshakeAuth {
    pub token: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct HandshakeInput {
    pub protocol_version: String,
    pub client: ClientInfo,
    pub auth: HandshakeAuth,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct HandshakeOutput {
    pub protocol_version: String,
    pub catalog_revision: u64,
    pub server: String,
    /// Which compositor Core is bound to, for measurement fingerprints.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub compositor: Option<String>,
    pub mode: CoreMode,
    /// The authorization subject this connection was bound to.
    pub subject: String,
    pub connection_id: String,
    /// Set for a hostd connection: increases with every new connection, so a
    /// lease from an earlier generation can be told apart and refused.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub host_generation: Option<u64>,
}
