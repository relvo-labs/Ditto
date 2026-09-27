//! Transaction participants. The Shell and hostd answer over their
//! connections; the compositor adapter answers in-process. The hot-swap
//! executor is written once against [`Participant`], so a Dock swap in the
//! Shell and a service swap in hostd run through the same tested steps.

use std::{
    collections::HashMap,
    sync::{Arc, Mutex},
    time::Duration,
};

use ditto_compositor::AdapterError;
use ditto_protocol::participant::{
    ChangePhase, CompositorObservation, CompositorProjection, ItemReport, ItemStatus, Observation,
    ParticipantPhase, ParticipantRole, PrepareParams, Projection, StateOutput, StepReport, ABORT,
    COMMIT, PREPARE, ROLLBACK, STATE,
};
use serde_json::{json, Value};

use crate::{
    peers::{Peer, PeerError},
    session::Session,
};

/// Proposed values (plan/03/02 §9.1); G1-QA-06 measures and may adjust them.
pub const PREPARE_TIMEOUT: Duration = Duration::from_secs(10);
pub const COMMIT_TIMEOUT: Duration = Duration::from_secs(5);
pub const ABORT_TIMEOUT: Duration = Duration::from_secs(5);
pub const ROLLBACK_TIMEOUT: Duration = Duration::from_secs(5);
pub const STATE_TIMEOUT: Duration = Duration::from_secs(2);

#[derive(Clone, Debug, PartialEq)]
pub enum ParticipantError {
    /// Not connected at all.
    Unavailable,
    /// Connected, then lost during the call: the effect is unknown.
    Disconnected,
    Timeout,
    Refused(String),
}

impl ParticipantError {
    pub fn key(&self) -> &'static str {
        match self {
            Self::Unavailable => "participant.unavailable",
            Self::Disconnected => "participant.disconnected",
            Self::Timeout => "participant.timeout",
            Self::Refused(_) => "participant.refused",
        }
    }
}

impl From<PeerError> for ParticipantError {
    fn from(error: PeerError) -> Self {
        match error {
            PeerError::Disconnected => Self::Disconnected,
            PeerError::Timeout => Self::Timeout,
            PeerError::Remote(error) => Self::Refused(error.message),
        }
    }
}

pub type ParticipantResult<T> = Result<T, ParticipantError>;

pub trait Participant: Send + Sync {
    fn role(&self) -> ParticipantRole;
    fn prepare(&self, params: &PrepareParams, timeout: Duration) -> ParticipantResult<StepReport>;
    fn commit(&self, change_id: &str, timeout: Duration) -> ParticipantResult<StepReport>;
    fn abort(&self, change_id: &str, timeout: Duration) -> ParticipantResult<()>;
    fn rollback(&self, change_id: &str, timeout: Duration) -> ParticipantResult<StepReport>;
    fn state(&self, change_id: Option<&str>, timeout: Duration) -> ParticipantResult<StateOutput>;
}

/// A participant on the other end of a connection.
pub struct RemoteParticipant {
    role: ParticipantRole,
    peer: Arc<Peer>,
}

impl RemoteParticipant {
    pub fn new(role: ParticipantRole, peer: Arc<Peer>) -> Self {
        Self { role, peer }
    }

    fn call<T: serde::de::DeserializeOwned>(
        &self,
        method: &str,
        params: Value,
        timeout: Duration,
    ) -> ParticipantResult<T> {
        let value = self.peer.request(method, params, timeout)?;
        serde_json::from_value(value)
            .map_err(|error| ParticipantError::Refused(format!("malformed answer: {error}")))
    }
}

impl Participant for RemoteParticipant {
    fn role(&self) -> ParticipantRole {
        self.role
    }

    fn prepare(&self, params: &PrepareParams, timeout: Duration) -> ParticipantResult<StepReport> {
        self.call(PREPARE, json!(params), timeout)
    }

    fn commit(&self, change_id: &str, timeout: Duration) -> ParticipantResult<StepReport> {
        self.call(COMMIT, json!({ "change_id": change_id }), timeout)
    }

    fn abort(&self, change_id: &str, timeout: Duration) -> ParticipantResult<()> {
        self.peer
            .request(ABORT, json!({ "change_id": change_id }), timeout)?;
        Ok(())
    }

    fn rollback(&self, change_id: &str, timeout: Duration) -> ParticipantResult<StepReport> {
        self.call(ROLLBACK, json!({ "change_id": change_id }), timeout)
    }

    fn state(&self, change_id: Option<&str>, timeout: Duration) -> ParticipantResult<StateOutput> {
        let params = match change_id {
            Some(id) => json!({ "change_id": id }),
            None => json!({}),
        };
        self.call(STATE, params, timeout)
    }
}

/// Layout strategy and shortcut bindings, applied through the compositor
/// adapter. The projection it last committed is kept only to answer rollback;
/// what is true is always read back from the compositor.
pub struct CompositorParticipant {
    session: Arc<Session>,
    inner: Mutex<CompositorState>,
}

#[derive(Default)]
struct CompositorState {
    committed: Option<CompositorProjection>,
    candidates: HashMap<String, (CompositorProjection, Option<CompositorProjection>)>,
    phases: HashMap<String, ParticipantPhase>,
}

pub fn strategy_name(package: &str) -> Option<&'static str> {
    match package {
        "ditto.layout.floating" => Some("floating"),
        "ditto.layout.simple-tile" => Some("simple-tile"),
        _ => None,
    }
}

impl CompositorParticipant {
    pub fn new(session: Arc<Session>) -> Self {
        Self {
            session,
            inner: Mutex::new(CompositorState::default()),
        }
    }

    /// A restarted compositor lost everything Core applied over IPC (options
    /// set over IPC are not saved to its configuration): the next sync must
    /// apply the whole projection, not a difference.
    pub fn forget(&self) {
        self.inner.lock().expect("compositor participant").committed = None;
    }

    fn observe(&self) -> CompositorObservation {
        let strategy = self
            .session
            .with_adapter(|adapter| adapter.layout_strategy())
            .ok()
            .flatten();
        let shortcuts = self
            .session
            .with_adapter(|adapter| adapter.shortcuts())
            .unwrap_or_default();
        let workspace_grid = self
            .session
            .with_adapter(|adapter| adapter.workspace_grid())
            .ok()
            .flatten();
        CompositorObservation {
            strategy,
            shortcuts,
            workspace_grid,
        }
    }

    fn apply(
        &self,
        projection: &CompositorProjection,
        previous: Option<&CompositorProjection>,
    ) -> Vec<ItemReport> {
        let mut items = Vec::new();
        let strategy_changed = previous.is_none_or(|old| old.strategy != projection.strategy);
        if strategy_changed {
            if let Some(name) = projection.strategy.as_deref().and_then(strategy_name) {
                let outcome = self
                    .session
                    .with_adapter(|adapter| adapter.set_layout_strategy(name));
                items.push(report("layout", outcome));
            }
        }
        let shortcuts_changed = previous.is_none_or(|old| old.shortcuts != projection.shortcuts);
        if shortcuts_changed {
            let outcome = self
                .session
                .with_adapter(|adapter| adapter.bind_shortcuts(&projection.shortcuts));
            items.push(report("shortcuts", outcome));
        }
        items
    }
}

fn report(key: &str, outcome: Result<(), AdapterError>) -> ItemReport {
    match outcome {
        Ok(()) => ItemReport {
            key: key.into(),
            status: ItemStatus::Applied,
            reason: None,
            missing: vec![],
        },
        Err(error) => ItemReport {
            key: key.into(),
            status: ItemStatus::Failed,
            reason: Some(format!("{error:?}")),
            missing: vec![],
        },
    }
}

impl Participant for CompositorParticipant {
    fn role(&self) -> ParticipantRole {
        ParticipantRole::Compositor
    }

    /// Prepare checks the compositor can do it without doing it: an
    /// unsupported strategy or binding path fails here, before any effect.
    fn prepare(&self, params: &PrepareParams, _timeout: Duration) -> ParticipantResult<StepReport> {
        let Projection::Compositor(target) = &params.target else {
            return Err(ParticipantError::Refused(
                "not a compositor projection".into(),
            ));
        };
        let mut inner = self.inner.lock().expect("compositor participant");
        let previous = inner.committed.clone();
        let mut items = Vec::new();
        if previous
            .as_ref()
            .is_none_or(|old| old.strategy != target.strategy)
        {
            if let Some(package) = &target.strategy {
                let supported = strategy_name(package).is_some_and(|name| {
                    self.session
                        .with_adapter(|adapter| Ok(adapter.supports_layout_strategy(name)))
                        .unwrap_or(false)
                });
                items.push(ItemReport {
                    key: "layout".into(),
                    status: if supported {
                        ItemStatus::Ready
                    } else {
                        ItemStatus::Failed
                    },
                    reason: (!supported)
                        .then(|| "layout strategy not supported by the compositor".into()),
                    missing: vec![],
                });
            }
        }
        if previous
            .as_ref()
            .is_none_or(|old| old.shortcuts != target.shortcuts)
        {
            let supported = self
                .session
                .with_adapter(|adapter| Ok(adapter.supports_shortcut_binding()))
                .unwrap_or(false);
            items.push(ItemReport {
                key: "shortcuts".into(),
                status: if supported {
                    ItemStatus::Ready
                } else {
                    ItemStatus::Failed
                },
                reason: (!supported).then(|| "the compositor has no shortcut binding path".into()),
                missing: vec![],
            });
        }
        inner
            .candidates
            .insert(params.change_id.clone(), (target.clone(), previous));
        inner
            .phases
            .insert(params.change_id.clone(), ParticipantPhase::Prepared);
        Ok(StepReport { items })
    }

    fn commit(&self, change_id: &str, _timeout: Duration) -> ParticipantResult<StepReport> {
        let (target, previous) = {
            let inner = self.inner.lock().expect("compositor participant");
            inner
                .candidates
                .get(change_id)
                .cloned()
                .ok_or_else(|| ParticipantError::Refused("unknown change".into()))?
        };
        let items = self.apply(&target, previous.as_ref());
        let mut inner = self.inner.lock().expect("compositor participant");
        inner.committed = Some(target);
        inner
            .phases
            .insert(change_id.into(), ParticipantPhase::Committed);
        Ok(StepReport { items })
    }

    fn abort(&self, change_id: &str, _timeout: Duration) -> ParticipantResult<()> {
        let mut inner = self.inner.lock().expect("compositor participant");
        inner.candidates.remove(change_id);
        inner
            .phases
            .insert(change_id.into(), ParticipantPhase::Aborted);
        Ok(())
    }

    fn rollback(&self, change_id: &str, _timeout: Duration) -> ParticipantResult<StepReport> {
        let (target, previous) = {
            let inner = self.inner.lock().expect("compositor participant");
            inner
                .candidates
                .get(change_id)
                .cloned()
                .ok_or_else(|| ParticipantError::Refused("unknown change".into()))?
        };
        let mut items = Vec::new();
        if let Some(previous) = &previous {
            for item in self.apply(previous, Some(&target)) {
                items.push(ItemReport {
                    status: if item.status == ItemStatus::Applied {
                        ItemStatus::Restored
                    } else {
                        ItemStatus::NotRestored
                    },
                    ..item
                });
            }
        }
        let mut inner = self.inner.lock().expect("compositor participant");
        inner.committed = previous;
        inner
            .phases
            .insert(change_id.into(), ParticipantPhase::RolledBack);
        Ok(StepReport { items })
    }

    fn state(&self, change_id: Option<&str>, _timeout: Duration) -> ParticipantResult<StateOutput> {
        let phase = change_id.map(|id| ChangePhase {
            change_id: id.into(),
            phase: self
                .inner
                .lock()
                .expect("compositor participant")
                .phases
                .get(id)
                .copied()
                .unwrap_or(ParticipantPhase::Unknown),
        });
        Ok(StateOutput {
            change: phase,
            observed: Observation::Compositor(self.observe()),
        })
    }
}
