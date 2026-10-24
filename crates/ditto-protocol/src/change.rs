//! ChangeSet: the only path by which Profile content changes. A GUI action, a
//! CLI command, a rescue action and (from G2) the Agent all produce one of
//! these, and Core alone runs it through preflight, prepare, apply, readback
//! and commit or rollback.

use std::collections::BTreeMap;

use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::profile::{DiffItem, HostKind};

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct NewEntry {
    pub package: String,
    pub version: String,
    pub host: HostKind,
    #[serde(default = "empty_object")]
    pub config: Value,
    #[serde(default)]
    pub disabled: bool,
}

fn empty_object() -> Value {
    Value::Object(Default::default())
}

/// `before` fields are intent: Core refills them from the base revision and
/// refuses the change when a caller-supplied value disagrees, because the
/// caller planned against a state that no longer exists.
#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(tag = "op", rename_all = "snake_case", deny_unknown_fields)]
pub enum ChangeOp {
    SetValue {
        /// JSON pointer into the document, limited to `/appearance`, `/avatar`,
        /// `/layout` and `/shortcuts`.
        path: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        before: Option<Value>,
        after: Value,
    },
    AddEntry {
        entry: NewEntry,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        slot: Option<String>,
    },
    RemoveEntry {
        entry_id: String,
    },
    SetEntryConfig {
        entry_id: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        before: Option<Value>,
        /// The whole new config. Preflight accepts only an object, and the
        /// schema says so, so a model is not left to guess (a JSON-encoded
        /// string is rejected, never parsed).
        #[schemars(with = "serde_json::Map<String, Value>")]
        after: Value,
    },
    SetEntryDisabled {
        entry_id: String,
        disabled: bool,
    },
    UpgradeEntry {
        entry_id: String,
        from_version: String,
        to_version: String,
    },
    BindSlot {
        slot: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        from: Option<String>,
        to: String,
    },
    SwitchProfile {
        to_profile: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        to_revision: Option<String>,
    },
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq, Hash)]
#[serde(rename_all = "snake_case")]
pub enum ChangeState {
    Draft,
    Validated,
    Rejected,
    Prepared,
    Aborted,
    Applying,
    Verifying,
    Committed,
    RollingBack,
    RolledBack,
    PartiallyApplied,
    Unknown,
}

impl ChangeState {
    pub const ALL: [Self; 12] = [
        Self::Draft,
        Self::Validated,
        Self::Rejected,
        Self::Prepared,
        Self::Aborted,
        Self::Applying,
        Self::Verifying,
        Self::Committed,
        Self::RollingBack,
        Self::RolledBack,
        Self::PartiallyApplied,
        Self::Unknown,
    ];

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Draft => "draft",
            Self::Validated => "validated",
            Self::Rejected => "rejected",
            Self::Prepared => "prepared",
            Self::Aborted => "aborted",
            Self::Applying => "applying",
            Self::Verifying => "verifying",
            Self::Committed => "committed",
            Self::RollingBack => "rolling_back",
            Self::RolledBack => "rolled_back",
            Self::PartiallyApplied => "partially_applied",
            Self::Unknown => "unknown",
        }
    }

    pub fn parse(text: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|state| state.as_str() == text)
    }

    pub fn is_terminal(self) -> bool {
        matches!(
            self,
            Self::Rejected
                | Self::Aborted
                | Self::Committed
                | Self::RolledBack
                | Self::PartiallyApplied
                | Self::Unknown
        )
    }

    /// The legal transitions. The store enforces the same table with a
    /// trigger, so a bug in Core cannot write an illegal state either.
    /// `unknown` is reachable only from an in-flight state, during recovery.
    pub fn allowed_next(self) -> &'static [ChangeState] {
        use ChangeState::*;
        match self {
            Draft => &[Validated, Rejected],
            Validated => &[Prepared, Aborted, Rejected],
            Prepared => &[Applying, Aborted],
            Applying => &[Verifying, RollingBack, Unknown],
            Verifying => &[Committed, RollingBack, Unknown],
            RollingBack => &[RolledBack, PartiallyApplied, Unknown],
            Rejected | Aborted | Committed | RolledBack | PartiallyApplied | Unknown => &[],
        }
    }

    pub fn result(self) -> Option<ResultKind> {
        match self {
            Self::Committed => Some(ResultKind::Succeeded),
            Self::Rejected | Self::Aborted | Self::RolledBack => Some(ResultKind::Failed),
            Self::PartiallyApplied => Some(ResultKind::Partial),
            Self::Unknown => Some(ResultKind::Unknown),
            _ => None,
        }
    }
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ResultKind {
    Succeeded,
    Failed,
    Partial,
    Unknown,
    /// Committed as a revision, but nothing took effect yet: every item is
    /// `scheduled` (session-restart level: at the next login; in rescue mode:
    /// when the normal mode returns). Never presented as "applied".
    Scheduled,
}

/// The result class of a change: the state's, except that a committed change
/// whose every item is scheduled has not taken effect and says so, and a
/// committed change that lists an item it could not restore (an undo that
/// met a closed window) is partial, never "succeeded".
pub fn result_of(state: ChangeState, items: &[OutcomeItem]) -> Option<ResultKind> {
    if state == ChangeState::Committed
        && !items.is_empty()
        && items
            .iter()
            .all(|item| item.status == OutcomeStatus::Scheduled)
    {
        return Some(ResultKind::Scheduled);
    }
    if state == ChangeState::Committed
        && items
            .iter()
            .any(|item| item.status == OutcomeStatus::NotRestored)
    {
        return Some(ResultKind::Partial);
    }
    state.result()
}

#[derive(
    Clone, Copy, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq, PartialOrd, Ord,
)]
#[serde(rename_all = "snake_case")]
pub enum HotSwapLevel {
    Instant,
    ControlledHandoff,
    HostRestart,
    SessionRestart,
}

impl HotSwapLevel {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Instant => "instant",
            Self::ControlledHandoff => "controlled_handoff",
            Self::HostRestart => "host_restart",
            Self::SessionRestart => "session_restart",
        }
    }

    pub fn parse(text: &str) -> Option<Self> {
        [
            Self::Instant,
            Self::ControlledHandoff,
            Self::HostRestart,
            Self::SessionRestart,
        ]
        .into_iter()
        .find(|level| level.as_str() == text)
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum ChangeOrigin {
    Gui {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        surface: Option<String>,
    },
    Cli,
    AgentStandin,
    Agent {
        session_id: String,
        turn_id: String,
        tool_call_id: String,
    },
    Rescue,
    Supervisor {
        reason: String,
    },
    TimedRevert {
        reverts: String,
    },
    Undo {
        undoes: String,
    },
    Import,
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq, Hash)]
#[serde(rename_all = "snake_case")]
pub enum PreflightCode {
    BaseRevisionStale,
    SchemaInvalid,
    StaleIntent,
    PackageMissing,
    IntegrityMismatch,
    ProtocolIncompatible,
    DependencyMissing,
    DependencyCycle,
    VersionConflict,
    DeclaredConflict,
    SingleProviderViolation,
    ShortcutConflict,
    CommandConflict,
    PermissionRequired,
    PreconditionFailed,
    BudgetExceeded,
}

impl PreflightCode {
    pub fn key(self) -> String {
        let wire = serde_json::to_value(self).expect("code serializes");
        format!("preflight.{}", wire.as_str().expect("code is a string"))
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct PreflightReason {
    pub code: PreflightCode,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub op_index: Option<u32>,
    pub detail_key: String,
    #[serde(default)]
    pub detail: BTreeMap<String, Value>,
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum OutcomeStatus {
    Applied,
    Failed,
    Restored,
    NotRestored,
    Pending,
    /// Session-restart level: recorded, applied at the next login.
    Scheduled,
}

/// What happened to one op, as read back. A partial result lists every item.
#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct OutcomeItem {
    pub op_index: u32,
    pub participant: String,
    pub key: String,
    pub status: OutcomeStatus,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(tag = "state", rename_all = "snake_case")]
pub enum Confirmation {
    NotRequired,
    Pending { deadline: String },
    Confirmed { at: String },
    Reverted { by_change: String },
}

/// The change card: prototype contract (kind, title, items, footnote), with
/// translation keys instead of text.
#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct ChangeCard {
    pub kind: String,
    pub title_key: String,
    #[serde(default)]
    pub title_args: BTreeMap<String, Value>,
    pub items: Vec<DiffItem>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub footnote_key: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct OperationSummary {
    pub operation_id: String,
    pub seq: u32,
    pub participant: String,
    pub step: String,
    pub state: String,
    pub started_at: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ended_at: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct ChangeSummary {
    pub change_id: String,
    pub profile_id: String,
    pub state: ChangeState,
    pub result: Option<ResultKind>,
    pub origin: ChangeOrigin,
    pub hot_swap_level: HotSwapLevel,
    pub title_key: String,
    pub committed_revision: Option<String>,
    pub confirmation: Confirmation,
    /// As on [`ChangeRecord::saved_only`].
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub saved_only: Option<SavedOnly>,
    /// As on [`ChangeRecord::profile_deleted`].
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub profile_deleted: bool,
    pub created_at: String,
    pub updated_at: String,
}

/// A committed change that wrote its Profile's revision and applied nothing
/// to the desktop (protocol 0.2 §8.1). `result` stays `succeeded`: the edit
/// of the stored Profile is done; this says where it went.
#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct SavedOnly {
    pub reason: SavedOnlyReason,
    /// The Profile's name when the record is read (it can be renamed since).
    pub profile_name: String,
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum SavedOnlyReason {
    /// The change's Profile was not the active one. It takes effect when
    /// that Profile is switched to.
    InactiveProfile,
}

impl SavedOnlyReason {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::InactiveProfile => "inactive_profile",
        }
    }

    pub fn parse(text: &str) -> Option<Self> {
        match text {
            "inactive_profile" => Some(Self::InactiveProfile),
            _ => None,
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct ChangeRecord {
    pub change_id: String,
    pub profile_id: String,
    pub base_revision: String,
    /// The revision this change produced, once committed.
    pub committed_revision: Option<String>,
    pub state: ChangeState,
    pub result: Option<ResultKind>,
    pub hot_swap_level: HotSwapLevel,
    pub origin: ChangeOrigin,
    pub idempotency_key: Option<String>,
    pub ops: Vec<ChangeOp>,
    pub card: ChangeCard,
    /// Every preflight failure, when rejected.
    #[serde(default)]
    pub reasons: Vec<PreflightReason>,
    /// Per-op outcomes as read back.
    #[serde(default)]
    pub items: Vec<OutcomeItem>,
    pub confirmation: Confirmation,
    #[serde(default)]
    pub operations: Vec<OperationSummary>,
    /// Set when boot recovery decided this change's outcome.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub recovered_at: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub failure_key: Option<String>,
    /// Present only when the change was committed without anything being
    /// applied to the desktop because its Profile was not active (#169).
    /// Absent on every other record and on every record written before
    /// store schema 6; absence alone does not mean the change was applied,
    /// `state` and `result` still say what happened.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub saved_only: Option<SavedOnly>,
    /// The change's Profile has been deleted since (#171), read when the
    /// record is read (the delete is soft; the record stays). The Profile
    /// cannot be switched to any more, so nothing of it applies again, and
    /// undo is refused (protocol 0.2 §8.6). Left out while false.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub profile_deleted: bool,
    pub created_at: String,
    pub updated_at: String,
}

impl ChangeRecord {
    pub fn summary(&self) -> ChangeSummary {
        ChangeSummary {
            change_id: self.change_id.clone(),
            profile_id: self.profile_id.clone(),
            state: self.state,
            result: self.result,
            origin: self.origin.clone(),
            hot_swap_level: self.hot_swap_level,
            title_key: self.card.title_key.clone(),
            committed_revision: self.committed_revision.clone(),
            confirmation: self.confirmation.clone(),
            saved_only: self.saved_only.clone(),
            profile_deleted: self.profile_deleted,
            created_at: self.created_at.clone(),
            updated_at: self.updated_at.clone(),
        }
    }
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq, Default)]
#[serde(rename_all = "snake_case")]
pub enum ChangeMode {
    #[default]
    Apply,
    /// Try it: committed with a countdown; `changes.confirm` keeps it,
    /// cancelling or letting the countdown lapse reverts it.
    Preview,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct ChangesProposeInput {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub profile_id: Option<String>,
    pub base_revision: String,
    pub ops: Vec<ChangeOp>,
    #[serde(default)]
    pub mode: ChangeMode,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub idempotency_key: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub surface: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq, Default)]
#[serde(deny_unknown_fields)]
pub struct ChangesGetInput {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub change_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub operation_id: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq, Default)]
#[serde(deny_unknown_fields)]
pub struct ChangesListInput {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub profile_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub limit: Option<u32>,
    /// Only changes created before this change id.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub before: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct ChangesListOutput {
    pub changes: Vec<ChangeSummary>,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct ChangeIdInput {
    pub change_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub idempotency_key: Option<String>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_terminal_state_has_a_result_and_no_successor() {
        for state in ChangeState::ALL {
            assert_eq!(state.is_terminal(), state.result().is_some(), "{state:?}");
            if state.is_terminal() {
                assert!(state.allowed_next().is_empty());
            }
            assert_eq!(ChangeState::parse(state.as_str()), Some(state));
        }
    }

    #[test]
    fn ops_are_tagged_and_reject_unknown_fields() {
        let op: ChangeOp = serde_json::from_value(serde_json::json!({
            "op": "bind_slot", "slot": "ui.dock", "to": "ent-x"
        }))
        .unwrap();
        assert!(matches!(op, ChangeOp::BindSlot { from: None, .. }));
        assert!(serde_json::from_value::<ChangeOp>(serde_json::json!({
            "op": "bind_slot", "slot": "ui.dock", "to": "ent-x", "force": true
        }))
        .is_err());
    }
}
