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
    profile::{Appearance, AvatarCorner, AvatarSettings, LayoutIntent, ShortcutBinding},
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
    /// Set when this change undoes an earlier one: a participant that kept
    /// state outside the profile for that change (window placement before a
    /// layout strategy switch) restores it and reports what it could not.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub undoes: Option<String>,
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
    /// Where the character actually is, as the Shell laid it out. `avatar`
    /// above echoes the settings; this is the readback of their effect.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub avatar_placement: Option<AvatarPlacement>,
    /// The Shell shows approval requests and can answer them. Without it an
    /// Agent's approval request is recorded as unavailable at once: nobody
    /// would see it, and waiting would only stall the turn.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub approval_responder: bool,
}

/// The character's placement as the Shell observes it after laying it out.
#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct AvatarPlacement {
    /// The output the character's surface is on; absent when it has no
    /// surface (turned off, or no output connected).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub output: Option<String>,
    /// True when the Profile names no output, or names one that is not
    /// connected, and the character is on the primary output instead.
    pub follows_primary: bool,
    pub corner: AvatarCorner,
    /// The surface rectangle in logical pixels, relative to `output`.
    pub x: i32,
    pub y: i32,
    pub width: u32,
    pub height: u32,
    /// On screen: false while hidden or turned off.
    pub visible: bool,
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
    /// Each open window a region rule covers, with where it actually is.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub regions: Vec<RegionPlacement>,
}

/// One window under a region rule, read back from the compositor.
#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct RegionPlacement {
    pub rule_id: String,
    pub window_id: String,
    /// Where the rule puts it, in output-relative logical pixels.
    pub target: [i64; 4],
    /// Where the compositor reports it; absent when it cannot say.
    pub observed: Option<[i64; 4]>,
}

/// Window borders and rounding: placements within this many logical pixels
/// of the target count as placed (plan/04/05 §5).
pub const REGION_TOLERANCE_PX: i64 = 2;

impl RegionPlacement {
    pub fn placed(&self) -> bool {
        self.observed.is_some_and(|seen| {
            seen.iter()
                .zip(self.target.iter())
                .all(|(a, b)| (a - b).abs() <= REGION_TOLERANCE_PX)
        })
    }
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
