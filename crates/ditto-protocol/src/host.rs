//! Core ↔ `ditto-hostd`. See `docs/contracts/host-protocol.md`: hostd keeps no
//! entries of its own, publishes capabilities only under a lease, and speaks
//! for an entry only when Core assigned that entry to its connection.

use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::participant::{EntryMode, FiberState};

pub const HELLO: &str = "host.hello";
pub const HEARTBEAT: &str = "host.heartbeat";
pub const CAPABILITY_REGISTER: &str = "host.capability.register";
pub const CAPABILITY_REVOKE: &str = "host.capability.revoke";
pub const LEASE_RENEW: &str = "host.lease.renew";
pub const EVENT: &str = "host.event";
pub const ENTRY_STATE: &str = "host.entry_state";
pub const RESOURCES: &str = "host.resources";
/// Core → hostd.
pub const INVOKE: &str = "host.invoke";
/// Core → hostd notification.
pub const PERMISSION_REVOKED: &str = "host.permission_revoked";

pub const HEARTBEAT_INTERVAL_MS: u64 = 2_000;
pub const HEARTBEAT_TIMEOUT_MS: u64 = 6_000;
pub const LEASE_TTL_MS: u64 = 10_000;
pub const LEASE_RENEW_INTERVAL_MS: u64 = 3_000;

/// Methods that need no `on_behalf_of`: they concern the host process, not
/// one of its entries.
pub const PROCESS_METHODS: &[&str] = &[HELLO, HEARTBEAT, LEASE_RENEW, ENTRY_STATE, RESOURCES];

#[derive(Clone, Copy, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum CandidateStrategy {
    /// D-32 strategy A: candidate in an isolate realm, rebuilt on commit.
    IsolateRebuild,
    /// D-32 strategy B: static checks at prepare, mount in place on commit.
    InPlace,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct HelloInput {
    pub hostd_version: String,
    pub node_version: String,
    pub cordis_version: String,
    pub vendor_fingerprint: String,
    pub strategy: CandidateStrategy,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct HelloOutput {
    pub host_generation: u64,
    pub mode: crate::rpc::CoreMode,
    pub heartbeat_interval_ms: u64,
    pub lease_ttl_ms: u64,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct RegisterInput {
    pub capability_id: String,
    pub version: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct RegisterOutput {
    pub lease_id: String,
    pub ttl_ms: u64,
    pub generation: u64,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct RevokeInput {
    pub lease_id: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct RenewInput {
    pub lease_ids: Vec<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct RenewOutput {
    pub renewed: Vec<String>,
    pub expired: Vec<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct EventInput {
    pub name: String,
    pub payload: Value,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub coalesce_key: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct EventOutput {
    pub accepted: bool,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct EntryStateReport {
    pub entry_id: String,
    pub fiber_state: FiberState,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mode: Option<EntryMode>,
    #[serde(default)]
    pub waiting_for: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub failure: Option<String>,
    pub effects: u32,
    pub timers: u32,
    pub subscriptions: u32,
    pub capabilities: u32,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct EntryStateInput {
    pub entries: Vec<EntryStateReport>,
}

/// Node heap figures. Three separate numbers: never summed with each other
/// or with the process PSS Core reads from `/proc` (NFR-15).
#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct ResourcesInput {
    pub heap_used: u64,
    pub external: u64,
    pub array_buffers: u64,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct InvokeParams {
    pub lease_id: String,
    pub entry_id: String,
    pub capability_id: String,
    pub input: Value,
    pub caller: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub operation_id: Option<String>,
    pub deadline_ms: u64,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct PermissionRevokedParams {
    pub entry_id: String,
    pub grant_id: String,
    pub scope: String,
}
