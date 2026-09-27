//! Transaction participants: the Shell, hostd and the compositor adapter take
//! the same five calls. Core sends each one the full desired state it is
//! responsible for (a projection), never a diff; the participant compares it
//! with what it runs. Boot, reconnect, change and rollback are the same path.

use std::collections::BTreeMap;

use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::{
    change::HotSwapLevel,
    profile::{Appearance, AvatarSettings, LayoutIntent, ShortcutBinding},
};

pub const PREPARE: &str = "participant.prepare";
pub const COMMIT: &str = "participant.commit";
pub const ABORT: &str = "participant.abort";
pub const ROLLBACK: &str = "participant.rollback";
pub const STATE: &str = "participant.state";

pub const ORIGIN_CHANGE: &str = "change";
pub const ORIGIN_BOOT: &str = "participant_boot";

#[derive(
    Clone, Copy, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq, Hash, PartialOrd, Ord,
)]
#[serde(rename_all = "snake_case")]
pub enum ParticipantRole {
    Shell,
    Hostd,
    Compositor,
}

impl ParticipantRole {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Shell => "shell",
            Self::Hostd => "hostd",
            Self::Compositor => "compositor",
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct ShellSlotBinding {
    pub slot: String,
    pub entry_id: String,
    pub package: String,
    pub version: String,
    /// `file://` URL of the provider's `qml_entry` inside the package store.
    pub qml_url: String,
    pub config: Value,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct ShellProjection {
    pub appearance: Appearance,
    pub avatar: AvatarSettings,
    pub slots: Vec<ShellSlotBinding>,
    pub shortcuts: Vec<ShortcutBinding>,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct HostEntryProjection {
    pub entry_id: String,
    pub package: String,
    pub version: String,
    pub module_path: String,
    pub data_dir: String,
    pub config: Value,
    pub disabled: bool,
    pub provides: Vec<String>,
    pub hot_swap: HotSwapLevel,
    pub health_timeout_ms: u64,
    pub cleanup_timeout_ms: u64,
    /// File grants this entry holds, id → absolute path. The path is only
    /// ever sent to the process that holds the grant, never exported.
    #[serde(default)]
    pub file_grants: BTreeMap<String, String>,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct HostProjection {
    pub entries: Vec<HostEntryProjection>,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct CompositorProjection {
    /// Package of the `layout.strategy` provider.
    pub strategy: Option<String>,
    pub layout: LayoutIntent,
    pub shortcuts: Vec<ShortcutBinding>,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(tag = "role", rename_all = "snake_case")]
pub enum Projection {
    Shell(ShellProjection),
    Hostd(HostProjection),
    Compositor(CompositorProjection),
}

impl Projection {
    pub fn role(&self) -> ParticipantRole {
        match self {
            Self::Shell(_) => ParticipantRole::Shell,
            Self::Hostd(_) => ParticipantRole::Hostd,
            Self::Compositor(_) => ParticipantRole::Compositor,
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct PrepareParams {
    pub change_id: String,
    pub origin: String,
    pub target: Projection,
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ItemStatus {
    Ready,
    Failed,
    /// Waiting for a service: legal, but at prepare it counts as not ready.
    Pending,
    Applied,
    Restored,
    NotRestored,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct ItemReport {
    /// A slot name, an entry id, or `appearance`/`avatar`/`layout`/`shortcuts`.
    pub key: String,
    pub status: ItemStatus,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub missing: Vec<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Default)]
#[serde(deny_unknown_fields)]
pub struct StepReport {
    pub items: Vec<ItemReport>,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct ChangeRef {
    pub change_id: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq, Default)]
#[serde(deny_unknown_fields)]
pub struct StateParams {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub change_id: Option<String>,
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ParticipantPhase {
    Prepared,
    Committed,
    Aborted,
    RolledBack,
    /// The participant does not remember this change (it restarted).
    Unknown,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct ChangePhase {
    pub change_id: String,
    pub phase: ParticipantPhase,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct PanelMount {
    pub slot: String,
    pub entry_id: String,
    pub mounted: bool,
    pub visible: bool,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct ShellObservation {
    pub mounts: Vec<PanelMount>,
    pub appearance: Option<Appearance>,
    pub avatar: Option<AvatarSettings>,
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum FiberState {
    Pending,
    Loading,
    Active,
    Unloading,
    Disposed,
    Failed,
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum EntryMode {
    Candidate,
    Active,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct HostEntryObservation {
    pub entry_id: String,
    pub fiber_state: FiberState,
    pub mode: EntryMode,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub waiting_for: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub failure: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct HostObservation {
    pub entries: Vec<HostEntryObservation>,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct CompositorObservation {
    pub strategy: Option<String>,
    pub shortcuts: Vec<ShortcutBinding>,
    pub workspace_grid: Option<[u32; 2]>,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(tag = "role", rename_all = "snake_case")]
pub enum Observation {
    Shell(ShellObservation),
    Hostd(HostObservation),
    Compositor(CompositorObservation),
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct StateOutput {
    pub change: Option<ChangePhase>,
    pub observed: Observation,
}

/// `shell.report`: the Shell tells Core what is mounted after every change,
/// which is what `desktop.panels.list` answers from.
pub const SHELL_REPORT: &str = "shell.report";
/// `shell.command` (notification): Core asks the Shell to run a command the
/// Shell owns, such as `launcher.toggle`.
pub const SHELL_COMMAND: &str = "shell.command";

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct ShellCommandParams {
    pub command_id: String,
    #[serde(default)]
    pub args: Value,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn projections_carry_their_role_on_the_wire() {
        let projection = Projection::Hostd(HostProjection { entries: vec![] });
        let wire = serde_json::to_value(&projection).unwrap();
        assert_eq!(wire["role"], "hostd");
        let back: Projection = serde_json::from_value(wire).unwrap();
        assert_eq!(back.role(), ParticipantRole::Hostd);
    }
}
