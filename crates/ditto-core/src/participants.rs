//! Transaction participants. The Shell and hostd answer over their
//! connections; the compositor adapter answers in-process. The hot-swap
//! executor is written once against [`Participant`], so a Dock swap in the
//! Shell and a service swap in hostd run through the same tested steps.

use std::{
    collections::HashMap,
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};

use ditto_compositor::AdapterError;
use ditto_protocol::{
    participant::RegionPlacement,
    participant::{
        ChangePhase, CompositorObservation, CompositorProjection, ItemReport, ItemStatus,
        Observation, ParticipantPhase, ParticipantRole, PrepareParams, Projection, StateOutput,
        StepReport, ABORT, COMMIT, PREPARE, ROLLBACK, STATE,
    },
    profile::{RegionRule, ShortcutBinding},
    Window,
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
    /// Whether the connection the participant answers on is still the one it
    /// prepared on. An in-process participant is always connected.
    fn connected(&self) -> bool {
        true
    }
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

    fn connected(&self) -> bool {
        !self.peer.is_closed()
    }
}

/// Layout strategy and shortcut bindings, applied through the compositor
/// adapter. The projection it last committed is kept only to answer rollback;
/// what is true is always read back from the compositor.
pub struct CompositorParticipant {
    session: Arc<Session>,
    inner: Mutex<CompositorState>,
}

/// `(x, y, width, height)` in output-relative logical pixels.
type Rect = (i32, i32, u32, u32);

/// How many strategy switches keep the window placement they replaced.
/// Placement is session state, not profile state: it is held in memory only,
/// so an undo after a Core restart has nothing to put back and says nothing.
const PLACEMENTS_KEPT: usize = 16;

#[derive(Default)]
struct CompositorState {
    committed: Option<CompositorProjection>,
    candidates: HashMap<String, Candidate>,
    phases: HashMap<String, ParticipantPhase>,
    /// Window placement just before a committed strategy switch, by the
    /// change that switched; oldest first.
    placements: Vec<(String, Vec<Window>)>,
    /// The windows the last commit placed by region rules, as
    /// `(rule_id, window_id)`: what that commit's readback checks. A window
    /// moved by hand later is not checked again until a change touches it.
    last_placed: Vec<(String, String)>,
}

#[derive(Clone)]
struct Candidate {
    target: CompositorProjection,
    previous: Option<CompositorProjection>,
    undoes: Option<String>,
}

/// Core's own chords (rescue, lock): bound whatever the profile says, and
/// refused to any profile or plugin by preflight.
pub fn reserved_bindings() -> Vec<ShortcutBinding> {
    crate::preflight::RESERVED_CHORDS
        .iter()
        .map(|chord| ShortcutBinding {
            chord: (*chord).into(),
            command: reserved_command(chord).into(),
        })
        .collect()
}

pub fn reserved_command(chord: &str) -> &'static str {
    if chord.ends_with('L') {
        "session.lock"
    } else {
        "rescue.open"
    }
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

    /// The profile's bindings as the compositor holds them: Core's reserved
    /// chords are bound beside them but are not profile state.
    fn observe(&self) -> CompositorObservation {
        let strategy = self
            .session
            .with_adapter(|adapter| adapter.layout_strategy())
            .ok()
            .flatten();
        let reserved = reserved_bindings();
        let shortcuts = self
            .session
            .with_adapter(|adapter| adapter.shortcuts())
            .unwrap_or_default()
            .into_iter()
            .filter(|binding| !reserved.contains(binding))
            .collect();
        let workspace_grid = self
            .session
            .with_adapter(|adapter| adapter.workspace_grid())
            .ok()
            .flatten();
        let regions = self.region_readback();
        CompositorObservation {
            strategy,
            shortcuts,
            workspace_grid,
            regions,
        }
    }

    /// The first region rule that covers a window (by application id; the
    /// rule's `output` is where the window goes, not a filter).
    fn rule_for<'a>(regions: &'a [RegionRule], window: &Window) -> Option<&'a RegionRule> {
        regions
            .iter()
            .find(|rule| rule.matcher.app_id == window.app_id)
    }

    /// Where a rule puts a window: the rule's output (or the window's) and
    /// the rectangle in that output's work area.
    fn target_of(
        &self,
        rule: &RegionRule,
        window: &Window,
    ) -> Result<(String, Rect), AdapterError> {
        // A rule's output that is not connected falls back to the window's
        // own output; the rule keeps its output for when it returns.
        let connected = |name: &String| {
            self.session
                .with_adapter(|adapter| adapter.outputs())
                .unwrap_or_default()
                .iter()
                .any(|output| &output.name == name && output.enabled)
        };
        let output = rule
            .output
            .clone()
            .filter(connected)
            .or_else(|| window.output.clone())
            .ok_or_else(|| AdapterError::Unsupported("the window's output is not known".into()))?;
        let area = self
            .session
            .with_adapter(|adapter| adapter.workarea(&output))?;
        Ok((output, rule.region.resolve(area)))
    }

    /// Put one window where its rule says and read it back.
    fn place(&self, rule: &RegionRule, window: &Window) -> ItemReport {
        let key = format!("region:{}:{}", rule.rule_id, window.id.0);
        let outcome = self
            .target_of(rule, window)
            .and_then(|(output, (x, y, width, height))| {
                self.session.with_adapter(|adapter| {
                    if window.output.as_deref() != Some(output.as_str()) {
                        adapter.move_window_to_output(&window.id, &output, x, y)?;
                    }
                    adapter.place_window(&window.id, x, y, width, height)
                })
            });
        report(&key, outcome)
    }

    /// Apply the rules that are new or changed against `previous` to every
    /// open window they cover. Windows under unchanged rules keep where the
    /// person may have moved them.
    fn apply_regions(
        &self,
        target: &[RegionRule],
        previous: Option<&[RegionRule]>,
    ) -> (Vec<ItemReport>, Vec<(String, String)>) {
        let changed: Vec<&RegionRule> = target
            .iter()
            .filter(|rule| previous.is_none_or(|old| !old.contains(rule)))
            .collect();
        if changed.is_empty() {
            return (vec![], vec![]);
        }
        let mut items = Vec::new();
        let mut placed = Vec::new();
        for window in self.placement() {
            let Some(rule) = Self::rule_for(target, &window) else {
                continue;
            };
            if !changed.contains(&rule) {
                continue;
            }
            let item = self.place(rule, &window);
            if item.status == ItemStatus::Applied {
                placed.push((rule.rule_id.clone(), window.id.0.clone()));
            }
            items.push(item);
        }
        if !placed.is_empty() {
            self.settle(&placed);
        }
        (items, placed)
    }

    /// A configure is only a request: the client answers with the size it
    /// commits, which may differ (a floating window may keep its own width).
    /// The readback waits until the placed windows' geometry has stopped
    /// changing, so it judges what the client committed, not what was asked.
    fn settle(&self, placed: &[(String, String)]) {
        const MIN: Duration = Duration::from_millis(150);
        const MAX: Duration = Duration::from_millis(1500);
        const STEP: Duration = Duration::from_millis(50);
        type Geometry = (Option<i32>, Option<i32>, Option<u32>, Option<u32>);
        let geometry = || -> Vec<Geometry> {
            let windows = self.placement();
            placed
                .iter()
                .map(|(_, id)| {
                    windows
                        .iter()
                        .find(|w| &w.id.0 == id)
                        .map(|w| (w.x, w.y, w.width, w.height))
                        .unwrap_or_default()
                })
                .collect()
        };
        // Unchanged for MIN in a row, or MAX in all.
        let started = Instant::now();
        let mut stable_since = started;
        let mut last = geometry();
        while stable_since.elapsed() < MIN && started.elapsed() < MAX {
            std::thread::sleep(STEP);
            let now = geometry();
            if now != last {
                stable_since = Instant::now();
                last = now;
            }
        }
    }

    /// The last commit's placements, as the compositor reports them now.
    fn region_readback(&self) -> Vec<RegionPlacement> {
        let (placed, regions) = {
            let inner = self.inner.lock().expect("compositor participant");
            let regions = inner
                .committed
                .as_ref()
                .map(|c| c.layout.regions.clone())
                .unwrap_or_default();
            (inner.last_placed.clone(), regions)
        };
        if placed.is_empty() {
            return vec![];
        }
        let windows = self.placement();
        placed
            .iter()
            .filter_map(|(rule_id, window_id)| {
                let rule = regions.iter().find(|r| &r.rule_id == rule_id)?;
                let window = windows.iter().find(|w| &w.id.0 == window_id);
                let target = window
                    .and_then(|w| self.target_of(rule, w).ok())
                    .map(|(_, (x, y, w, h))| {
                        [i64::from(x), i64::from(y), i64::from(w), i64::from(h)]
                    })
                    .unwrap_or([0; 4]);
                let observed = window.and_then(|w| match (w.x, w.y, w.width, w.height) {
                    (Some(x), Some(y), Some(width), Some(height)) => Some([
                        i64::from(x),
                        i64::from(y),
                        i64::from(width),
                        i64::from(height),
                    ]),
                    _ => None,
                });
                Some(RegionPlacement {
                    rule_id: rule_id.clone(),
                    window_id: window_id.clone(),
                    target,
                    observed,
                })
            })
            .collect()
    }

    /// A window opened: if a committed rule covers it, place it. This is the
    /// event-driven half of D-40; it is not a change, so it reports to the
    /// log only.
    pub fn window_opened(&self, window: &Window) {
        let rule = {
            let inner = self.inner.lock().expect("compositor participant");
            inner
                .committed
                .as_ref()
                .and_then(|c| Self::rule_for(&c.layout.regions, window).cloned())
        };
        if let Some(rule) = rule {
            let item = self.place(&rule, window);
            crate::log::event(
                "layout.region_applied",
                &[
                    ("rule_id", rule.rule_id.as_str()),
                    ("window_id", window.id.0.as_str()),
                    (
                        "status",
                        if item.status == ItemStatus::Applied {
                            "applied"
                        } else {
                            "failed"
                        },
                    ),
                ],
            );
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
        // Bound again when the compositor's table is not what was committed
        // (a binding that failed at boot, a compositor that lost them), so a
        // change never fails its readback on bindings it did not touch.
        let shortcuts_changed = previous.is_none_or(|old| old.shortcuts != projection.shortcuts)
            || self.observe().shortcuts != projection.shortcuts;
        if shortcuts_changed {
            let mut bindings = projection.shortcuts.clone();
            bindings.extend(reserved_bindings());
            let outcome = self
                .session
                .with_adapter(|adapter| adapter.bind_shortcuts(&bindings));
            items.push(report("shortcuts", outcome));
        }
        items
    }

    fn strategy_changes(
        projection: &CompositorProjection,
        previous: Option<&CompositorProjection>,
    ) -> bool {
        projection.strategy.is_some()
            && previous.is_none_or(|old| old.strategy != projection.strategy)
    }

    /// Where every window is. A compositor that cannot list windows gives
    /// nothing to keep, and an undo then has nothing to report.
    fn placement(&self) -> Vec<Window> {
        self.session
            .with_adapter(|adapter| adapter.windows())
            .unwrap_or_default()
    }

    /// Put windows back where they were before the change being undone.
    /// A window closed since then cannot be: it is listed with its reason.
    fn restore_placement(&self, saved: &[Window]) -> Vec<ItemReport> {
        let present = self.placement();
        saved
            .iter()
            .map(|before| {
                let key = format!("window:{}", before.id.0);
                let Some(now) = present.iter().find(|window| window.id == before.id) else {
                    return ItemReport {
                        key,
                        status: ItemStatus::NotRestored,
                        reason: Some("window_closed".into()),
                        missing: vec![],
                    };
                };
                let mut outcome = Ok(());
                if let (Some(x), Some(y)) = (before.x, before.y) {
                    if (now.x, now.y) != (before.x, before.y) {
                        outcome = self
                            .session
                            .with_adapter(|adapter| adapter.move_window(&before.id, x, y));
                    }
                }
                if let (Ok(()), Some(width), Some(height)) = (&outcome, before.width, before.height)
                {
                    if (now.width, now.height) != (before.width, before.height) {
                        outcome = self.session.with_adapter(|adapter| {
                            adapter.resize_window(&before.id, width, height)
                        });
                    }
                }
                match outcome {
                    Ok(()) => ItemReport {
                        key,
                        status: ItemStatus::Restored,
                        reason: None,
                        missing: vec![],
                    },
                    Err(error) => ItemReport {
                        key,
                        status: ItemStatus::NotRestored,
                        reason: Some(format!("{error:?}")),
                        missing: vec![],
                    },
                }
            })
            .collect()
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
        if previous.as_ref().is_none_or(|old| {
            old.layout.regions != target.layout.regions || old.strategy != target.strategy
        }) && !target.layout.regions.is_empty()
        {
            // Regions are floating geometry: a tiler owns window geometry.
            let floating = target
                .strategy
                .as_deref()
                .is_none_or(|package| strategy_name(package) == Some("floating"));
            let outputs = self
                .session
                .with_adapter(|adapter| adapter.outputs())
                .unwrap_or_default();
            let measurable = outputs.iter().any(|output| {
                self.session
                    .with_adapter(|adapter| adapter.workarea(&output.name))
                    .is_ok()
            });
            let reason = if !floating {
                Some("region layout needs the floating layout strategy".to_string())
            } else if !measurable {
                Some("the compositor reports no work area to divide".to_string())
            } else {
                None
            };
            items.push(ItemReport {
                key: "regions".into(),
                status: if reason.is_none() {
                    ItemStatus::Ready
                } else {
                    ItemStatus::Failed
                },
                reason,
                missing: vec![],
            });
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
        inner.candidates.insert(
            params.change_id.clone(),
            Candidate {
                target: target.clone(),
                previous,
                undoes: params.undoes.clone(),
            },
        );
        inner
            .phases
            .insert(params.change_id.clone(), ParticipantPhase::Prepared);
        Ok(StepReport { items })
    }

    fn commit(&self, change_id: &str, _timeout: Duration) -> ParticipantResult<StepReport> {
        let candidate = {
            let inner = self.inner.lock().expect("compositor participant");
            inner
                .candidates
                .get(change_id)
                .cloned()
                .ok_or_else(|| ParticipantError::Refused("unknown change".into()))?
        };
        let switches = Self::strategy_changes(&candidate.target, candidate.previous.as_ref());
        let regions_changed = candidate
            .previous
            .as_ref()
            .is_none_or(|old| old.layout.regions != candidate.target.layout.regions);
        let moves = switches || regions_changed;
        let before = moves.then(|| self.placement());
        let mut items = self.apply(&candidate.target, candidate.previous.as_ref());
        let (region_items, placed) = if candidate.undoes.is_some() {
            (vec![], vec![])
        } else {
            self.apply_regions(
                &candidate.target.layout.regions,
                candidate
                    .previous
                    .as_ref()
                    .map(|old| old.layout.regions.as_slice()),
            )
        };
        items.extend(region_items);
        let saved = match (&candidate.undoes, moves) {
            (Some(undone), true) => {
                let inner = self.inner.lock().expect("compositor participant");
                inner
                    .placements
                    .iter()
                    .find(|(id, _)| id == undone)
                    .map(|(_, windows)| windows.clone())
            }
            _ => None,
        };
        if let Some(saved) = saved {
            items.extend(self.restore_placement(&saved));
        }
        let mut inner = self.inner.lock().expect("compositor participant");
        if let Some(before) = before {
            inner.placements.push((change_id.into(), before));
            if inner.placements.len() > PLACEMENTS_KEPT {
                inner.placements.remove(0);
            }
        }
        inner.last_placed = placed;
        inner.committed = Some(candidate.target);
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
        let Candidate {
            target, previous, ..
        } = {
            let inner = self.inner.lock().expect("compositor participant");
            inner
                .candidates
                .get(change_id)
                .cloned()
                .ok_or_else(|| ParticipantError::Refused("unknown change".into()))?
        };
        let mut items = Vec::new();
        // Geometry this change moved goes back first, then the projection.
        let saved = {
            let inner = self.inner.lock().expect("compositor participant");
            inner
                .placements
                .iter()
                .find(|(id, _)| id == change_id)
                .map(|(_, windows)| windows.clone())
        };
        if let Some(saved) = saved {
            items.extend(self.restore_placement(&saved));
        }
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
        inner.placements.retain(|(id, _)| id != change_id);
        inner.last_placed.clear();
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
