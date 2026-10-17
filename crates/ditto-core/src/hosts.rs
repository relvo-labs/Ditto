//! `ditto-hostd` supervision and the lease table (plan/03/02 §12, host
//! protocol §1–§10). Whether hostd runs is decided here from the Profile,
//! never from Agent idleness, and hostd itself never decides to exit. The
//! lease table is Core's own: a capability is routable only while its lease
//! is valid, and every lease dies with the connection that took it.

use std::{
    collections::{HashMap, VecDeque},
    process::Child,
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};

use ditto_protocol::{
    catalog::{self, Provider},
    host::{
        EntryStateInput, EntryStateReport, EventInput, HelloInput, RegisterInput, RegisterOutput,
        RenewInput, RenewOutput, ResourcesInput, HEARTBEAT_TIMEOUT_MS, LEASE_TTL_MS,
    },
    ids,
    manifest::EventDecl,
    participant::{FiberState, HostProjection},
    services::{HostStatus, NodeHeap, ProcessResources},
    ConflictReason, UnavailableReason,
};

use crate::{
    identity::IdentityRegistry,
    launcher::{self, Quota, Specification},
    peers::Peer,
};

pub const RESTART_BACKOFF: [u64; 5] = [1, 2, 4, 8, 30];
pub const CRASH_LOOP_WINDOW: Duration = Duration::from_secs(600);
pub const CRASH_LOOP_LIMIT: usize = 5;
pub const ENTRY_FAILURE_LIMIT: usize = 3;
pub const ENTRY_EARLY_CRASH_WINDOW: Duration = Duration::from_secs(30);
pub const ENTRY_EARLY_CRASH_LIMIT: usize = 2;
pub const RECYCLE_GRACE: Duration = Duration::from_secs(5);
/// Reserved `host.event` name: an entry's event queue overflowed in hostd.
pub const RESYNC_EVENT: &str = "resync_required";

#[derive(Clone, Copy)]
enum Counter {
    Failed,
    EarlyCrash,
}

/// What the host manager tells the rest of Core. Implemented by `Core`.
pub trait HostEvents: Send + Sync {
    fn host_ready(&self, generation: u64);
    fn host_lost(&self, generation: u64, reason: &str);
    fn capabilities_changed(&self, reason: &str);
    fn host_event(&self, entry_id: &str, name: &str, payload: serde_json::Value);
    /// Supervision decided this entry must be disabled (REC-02).
    fn disable_entry(&self, entry_id: &str, reason: &str);
    fn instability(&self, what: &str);
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum RunState {
    NotNeeded,
    Starting { since: Instant },
    Running,
    Backoff { until: Instant },
    CrashLoop,
    Rescue,
}

impl RunState {
    fn label(&self) -> &'static str {
        match self {
            Self::NotNeeded => "not_needed",
            Self::Starting { .. } => "starting",
            Self::Running => "running",
            Self::Backoff { .. } => "stopped",
            Self::CrashLoop => "crash_loop",
            Self::Rescue => "rescue_mode",
        }
    }
}

#[derive(Clone, Debug)]
pub struct Assigned {
    pub entry_id: String,
    pub package: String,
    pub provides: Vec<String>,
    pub events: Vec<EventDecl>,
    /// Committed and allowed to hold leases.
    pub active: bool,
    /// A change whose candidate for this entry is prepared but not committed.
    pub candidate_change: Option<String>,
    pub activated_at: Option<Instant>,
}

#[derive(Clone, Debug)]
struct Lease {
    entry_id: String,
    capability_id: String,
    generation: u64,
    expires: Instant,
}

struct Inner {
    run: RunState,
    needed: bool,
    peer: Option<Arc<Peer>>,
    generation: u64,
    last_heartbeat: Instant,
    hello: Option<HelloInput>,
    entries: HashMap<String, Assigned>,
    /// Entries staged by a change that are not assigned yet.
    staged: HashMap<String, Vec<Assigned>>,
    leases: HashMap<String, Lease>,
    reports: HashMap<String, EntryStateReport>,
    heap: Option<NodeHeap>,
    restarts: VecDeque<Instant>,
    failures: HashMap<String, VecDeque<Instant>>,
    child: Option<Child>,
    idle_since: Option<Instant>,
}

impl Inner {
    /// Whether `generation` is the connection Core currently serves. A
    /// connection Core dropped (heartbeat lapsed, or replaced) keeps its
    /// generation number until the next hostd attaches, but nothing it sends
    /// counts any more: not a heartbeat, not a lease (L-07 negative).
    fn live(&self, generation: u64) -> bool {
        self.generation == generation && self.peer.is_some()
    }
}

/// What a package declares that hostd may use: capabilities and events.
type Declared = (Vec<String>, Vec<EventDecl>);

pub struct HostManager {
    inner: Mutex<Inner>,
    spec: Option<Specification>,
    quota: Option<Quota>,
    registry: Arc<IdentityRegistry>,
    socket: std::path::PathBuf,
    events: Mutex<Option<Arc<dyn HostEvents>>>,
    manifests: Mutex<HashMap<String, Declared>>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum HostError {
    Identity,
    Conflict(ConflictReason),
    Invalid(String),
    Unavailable(UnavailableReason),
}

impl HostManager {
    pub fn new(
        spec: Option<Specification>,
        quota: Option<Quota>,
        registry: Arc<IdentityRegistry>,
        socket: std::path::PathBuf,
        rescue: bool,
    ) -> Self {
        Self {
            inner: Mutex::new(Inner {
                run: if rescue {
                    RunState::Rescue
                } else {
                    RunState::NotNeeded
                },
                needed: false,
                peer: None,
                generation: 0,
                last_heartbeat: Instant::now(),
                hello: None,
                entries: HashMap::new(),
                staged: HashMap::new(),
                leases: HashMap::new(),
                reports: HashMap::new(),
                heap: None,
                restarts: VecDeque::new(),
                failures: HashMap::new(),
                child: None,
                idle_since: None,
            }),
            spec,
            quota,
            registry,
            socket,
            events: Mutex::new(None),
            manifests: Mutex::new(HashMap::new()),
        }
    }

    pub fn set_events(&self, events: Arc<dyn HostEvents>) {
        *self.events.lock().expect("host events") = Some(events);
    }

    fn events(&self) -> Option<Arc<dyn HostEvents>> {
        self.events.lock().expect("host events").clone()
    }

    pub fn is_rescue(&self) -> bool {
        self.inner.lock().expect("host state").run == RunState::Rescue
    }

    /// Remember what each package declares (capabilities, events) so the
    /// checks at registration and event time need no store access.
    pub fn remember_manifest(&self, package: &str, provides: Vec<String>, events: Vec<EventDecl>) {
        self.manifests
            .lock()
            .expect("host manifests")
            .insert(package.to_string(), (provides, events));
    }

    // ---- lifecycle ----------------------------------------------------------

    /// Whether the active Profile needs hostd. Called after every commit and
    /// boot; starting and recycling follow from it.
    pub fn set_needed(&self, needed: bool) {
        let mut inner = self.inner.lock().expect("host state");
        inner.needed = needed;
        if needed {
            inner.idle_since = None;
        } else if inner.idle_since.is_none() {
            inner.idle_since = Some(Instant::now());
        }
    }

    pub fn peer(&self) -> Option<Arc<Peer>> {
        self.inner
            .lock()
            .expect("host state")
            .peer
            .clone()
            .filter(|peer| !peer.is_closed())
    }

    pub fn generation(&self) -> u64 {
        self.inner.lock().expect("host state").generation
    }

    pub fn is_ready(&self) -> bool {
        let inner = self.inner.lock().expect("host state");
        inner.run == RunState::Running
            && inner.hello.is_some()
            && inner.peer.as_ref().is_some_and(|peer| !peer.is_closed())
    }

    /// Start hostd now if it is needed and not running. Returns false when
    /// supervision forbids it (rescue mode, crash loop, no launch spec).
    pub fn ensure_started(&self) -> bool {
        let mut inner = self.inner.lock().expect("host state");
        match inner.run {
            RunState::Rescue | RunState::CrashLoop => return false,
            RunState::Running | RunState::Starting { .. } => return true,
            RunState::Backoff { until } if until > Instant::now() => return true,
            _ => {}
        }
        let Some(spec) = self.spec.clone() else {
            return false;
        };
        match launcher::launch_parsed(
            &self.registry,
            &spec,
            &self.socket,
            self.quota.as_ref(),
            &[],
        ) {
            Ok(child) => {
                inner.child = Some(child);
                inner.run = RunState::Starting {
                    since: Instant::now(),
                };
                true
            }
            Err(error) => {
                crate::log::event(
                    "host.start_refused",
                    &[
                        ("reason", &error.to_string()),
                        ("reason_code", &format!("{:?}", error.kind())),
                    ],
                );
                inner.run = RunState::Backoff {
                    until: Instant::now() + Duration::from_secs(RESTART_BACKOFF[0]),
                };
                false
            }
        }
    }

    /// Block until hostd said hello, at most `timeout`.
    pub fn wait_ready(&self, timeout: Duration) -> bool {
        let deadline = Instant::now() + timeout;
        while Instant::now() < deadline {
            if self.is_ready() {
                return true;
            }
            {
                let inner = self.inner.lock().expect("host state");
                if matches!(inner.run, RunState::CrashLoop | RunState::Rescue) {
                    return false;
                }
            }
            std::thread::sleep(Duration::from_millis(20));
        }
        self.is_ready()
    }

    /// A hostd connection finished its handshake.
    pub fn attach(&self, peer: Arc<Peer>) -> u64 {
        let mut inner = self.inner.lock().expect("host state");
        if let Some(old) = inner.peer.take() {
            old.close();
        }
        inner.generation += 1;
        inner.peer = Some(peer);
        inner.last_heartbeat = Instant::now();
        inner.hello = None;
        inner.entries.clear();
        inner.staged.clear();
        inner.leases.clear();
        inner.reports.clear();
        inner.generation
    }

    pub fn hello(&self, generation: u64, hello: HelloInput) -> Result<(), HostError> {
        {
            let mut inner = self.inner.lock().expect("host state");
            if !inner.live(generation) {
                return Err(HostError::Identity);
            }
            inner.hello = Some(hello);
            inner.run = RunState::Running;
            inner.last_heartbeat = Instant::now();
        }
        if let Some(events) = self.events() {
            events.host_ready(generation);
        }
        Ok(())
    }

    /// The connection ended. Everything it held is gone at once: this is the
    /// ≤500 ms unavailability EX1-08 measures, not a lease timeout.
    pub fn detach(&self, generation: u64, reason: &str) {
        let (was_running, early_crash) = {
            let mut inner = self.inner.lock().expect("host state");
            if !inner.live(generation) {
                return;
            }
            if let Some(peer) = inner.peer.take() {
                peer.close();
            }
            let now = Instant::now();
            let early: Vec<String> = inner
                .entries
                .values()
                .filter(|entry| {
                    entry
                        .activated_at
                        .is_some_and(|at| now.duration_since(at) < ENTRY_EARLY_CRASH_WINDOW)
                })
                .map(|entry| entry.entry_id.clone())
                .collect();
            inner.entries.clear();
            inner.staged.clear();
            inner.leases.clear();
            inner.reports.clear();
            inner.hello = None;
            let was_running = !matches!(inner.run, RunState::Rescue | RunState::NotNeeded);
            if matches!(inner.run, RunState::Rescue) {
                return;
            }
            if let Some(mut child) = inner.child.take() {
                let _ = child.try_wait();
            }
            if inner.needed {
                inner.restarts.push_back(now);
                while inner
                    .restarts
                    .front()
                    .is_some_and(|at| now.duration_since(*at) > CRASH_LOOP_WINDOW)
                {
                    inner.restarts.pop_front();
                }
                if inner.restarts.len() >= CRASH_LOOP_LIMIT {
                    inner.run = RunState::CrashLoop;
                } else {
                    let step =
                        RESTART_BACKOFF[(inner.restarts.len() - 1).min(RESTART_BACKOFF.len() - 1)];
                    inner.run = RunState::Backoff {
                        until: now + Duration::from_secs(step),
                    };
                }
            } else {
                inner.run = RunState::NotNeeded;
            }
            (was_running, early)
        };
        if let Some(events) = self.events() {
            events.host_lost(generation, reason);
            events.capabilities_changed("host_lost");
            if was_running {
                events.instability("hostd");
            }
            for entry_id in early_crash {
                let count = self.record(&entry_id, Counter::EarlyCrash);
                if count >= ENTRY_EARLY_CRASH_LIMIT {
                    events.disable_entry(&entry_id, "host_crashed_after_enable");
                }
            }
        }
    }

    /// Two separate counts (REC-02): an entry entering FAILED, and hostd
    /// dying shortly after the entry was enabled. They are not added up.
    fn record(&self, entry_id: &str, counter: Counter) -> usize {
        let mut inner = self.inner.lock().expect("host state");
        let now = Instant::now();
        let key = match counter {
            Counter::Failed => format!("failed:{entry_id}"),
            Counter::EarlyCrash => format!("early:{entry_id}"),
        };
        let failures = inner.failures.entry(key).or_default();
        failures.push_back(now);
        while failures
            .front()
            .is_some_and(|at| now.duration_since(*at) > CRASH_LOOP_WINDOW)
        {
            failures.pop_front();
        }
        failures.len()
    }

    /// Operator action from the plugin center: leave the crash loop.
    pub fn reset_crash_loop(&self) {
        let mut inner = self.inner.lock().expect("host state");
        if inner.run == RunState::CrashLoop {
            inner.restarts.clear();
            inner.run = RunState::NotNeeded;
        }
    }

    /// Periodic supervision: heartbeat deadline, lease expiry, restarts and
    /// recycling. Returns the generation to drop when the heartbeat lapsed.
    pub fn tick(&self) -> Option<u64> {
        let now = Instant::now();
        let mut expired_any = false;
        let mut kill = None;
        let mut start = false;
        let mut recycle = None;
        {
            let mut inner = self.inner.lock().expect("host state");
            let before = inner.leases.len();
            inner.leases.retain(|_, lease| lease.expires > now);
            expired_any = expired_any || inner.leases.len() != before;
            if inner.peer.is_some()
                && now.duration_since(inner.last_heartbeat)
                    > Duration::from_millis(HEARTBEAT_TIMEOUT_MS)
            {
                kill = inner.peer.as_ref().map(|peer| (peer.pid, inner.generation));
            }
            if inner.needed {
                match inner.run {
                    RunState::NotNeeded => start = true,
                    RunState::Backoff { until } if until <= now => start = true,
                    RunState::Starting { since }
                        if now.duration_since(since) > Duration::from_secs(15) =>
                    {
                        inner.run = RunState::Backoff { until: now };
                    }
                    _ => {}
                }
            } else if inner.peer.is_some()
                && inner.leases.is_empty()
                && inner.entries.is_empty()
                && inner
                    .idle_since
                    .is_some_and(|since| now.duration_since(since) > RECYCLE_GRACE)
            {
                recycle = inner.peer.as_ref().map(|peer| peer.pid);
                inner.run = RunState::NotNeeded;
            }
        }
        if expired_any {
            if let Some(events) = self.events() {
                events.capabilities_changed("lease_expired");
            }
        }
        if start {
            self.ensure_started();
        }
        if let Some(pid) = recycle {
            terminate(pid);
        }
        if let Some((pid, generation)) = kill {
            terminate(pid);
            return Some(generation);
        }
        None
    }

    // ---- entries and transactions --------------------------------------------

    /// Stage the entries of `projection` for `change_id` before prepare: new
    /// entries become assigned candidates, changed ones get a candidate mark.
    /// Registrations for a marked entry are refused until commit (L-03).
    pub fn stage(&self, change_id: &str, projection: &HostProjection) {
        let manifests = self.manifests.lock().expect("host manifests").clone();
        let mut inner = self.inner.lock().expect("host state");
        let mut staged = Vec::new();
        for entry in &projection.entries {
            let (provides, events) = manifests
                .get(&entry.package)
                .cloned()
                .unwrap_or_else(|| (entry.provides.clone(), vec![]));
            match inner.entries.get_mut(&entry.entry_id) {
                Some(assigned) => assigned.candidate_change = Some(change_id.to_string()),
                None => staged.push(Assigned {
                    entry_id: entry.entry_id.clone(),
                    package: entry.package.clone(),
                    provides,
                    events,
                    active: false,
                    candidate_change: Some(change_id.to_string()),
                    activated_at: None,
                }),
            }
        }
        // A candidate may call read capabilities during its health check, so
        // it is assigned (on_behalf_of accepted) but not active.
        for assigned in &staged {
            inner
                .entries
                .insert(assigned.entry_id.clone(), assigned.clone());
        }
        inner.staged.insert(change_id.to_string(), staged);
    }

    /// Just before `participant.commit`: the staged entries of `change_id`
    /// become active; entries absent from `projection` are leaving.
    /// Returns the entries that left, so their subscriptions can be closed.
    pub fn activate(&self, change_id: &str, projection: &HostProjection) -> Vec<String> {
        let mut inner = self.inner.lock().expect("host state");
        inner.staged.remove(change_id);
        let now = Instant::now();
        for assigned in inner.entries.values_mut() {
            if assigned.candidate_change.as_deref() == Some(change_id) {
                assigned.candidate_change = None;
                // Only an entry that starts now is "just enabled"; a config
                // change of a running one does not restart its crash clock.
                if !assigned.active {
                    assigned.activated_at = Some(now);
                }
                assigned.active = true;
            }
        }
        let keep: Vec<&str> = projection
            .entries
            .iter()
            .map(|entry| entry.entry_id.as_str())
            .collect();
        let leaving: Vec<String> = inner
            .entries
            .keys()
            .filter(|id| !keep.contains(&id.as_str()))
            .cloned()
            .collect();
        for entry_id in &leaving {
            inner.entries.remove(entry_id);
            inner.leases.retain(|_, lease| &lease.entry_id != entry_id);
        }
        leaving
    }

    /// After abort: staged entries disappear, marks are cleared.
    pub fn discard(&self, change_id: &str) {
        let mut inner = self.inner.lock().expect("host state");
        if let Some(staged) = inner.staged.remove(change_id) {
            for assigned in staged {
                inner.entries.remove(&assigned.entry_id);
            }
        }
        for assigned in inner.entries.values_mut() {
            if assigned.candidate_change.as_deref() == Some(change_id) {
                assigned.candidate_change = None;
            }
        }
    }

    /// Replace the assignment wholesale (boot sync after a reconnect).
    pub fn assign_all(&self, projection: &HostProjection) {
        let manifests = self.manifests.lock().expect("host manifests").clone();
        let mut inner = self.inner.lock().expect("host state");
        let now = Instant::now();
        inner.entries = projection
            .entries
            .iter()
            .map(|entry| {
                let (provides, events) = manifests
                    .get(&entry.package)
                    .cloned()
                    .unwrap_or_else(|| (entry.provides.clone(), vec![]));
                (
                    entry.entry_id.clone(),
                    Assigned {
                        entry_id: entry.entry_id.clone(),
                        package: entry.package.clone(),
                        provides,
                        events,
                        active: true,
                        candidate_change: None,
                        activated_at: Some(now),
                    },
                )
            })
            .collect();
        let keep: Vec<String> = inner.entries.keys().cloned().collect();
        inner
            .leases
            .retain(|_, lease| keep.contains(&lease.entry_id));
    }

    // ---- requests from hostd ---------------------------------------------

    /// `on_behalf_of` is accepted only for an entry Core assigned to this
    /// connection's generation (EX1-06 ⑤).
    pub fn validate(&self, generation: u64, entry_id: &str) -> bool {
        let inner = self.inner.lock().expect("host state");
        inner.live(generation) && inner.entries.contains_key(entry_id)
    }

    pub fn heartbeat(&self, generation: u64) -> Result<(), HostError> {
        let mut inner = self.inner.lock().expect("host state");
        if !inner.live(generation) {
            return Err(HostError::Identity);
        }
        inner.last_heartbeat = Instant::now();
        Ok(())
    }

    pub fn register(
        &self,
        generation: u64,
        entry_id: &str,
        input: &RegisterInput,
    ) -> Result<RegisterOutput, HostError> {
        let output = {
            let mut inner = self.inner.lock().expect("host state");
            if !inner.live(generation) {
                return Err(HostError::Identity);
            }
            let Some(assigned) = inner.entries.get(entry_id) else {
                return Err(HostError::Identity);
            };
            if assigned.candidate_change.is_some() || !assigned.active {
                return Err(HostError::Conflict(ConflictReason::CandidateCannotClaim));
            }
            if !assigned
                .provides
                .iter()
                .any(|provided| provided == &input.capability_id)
            {
                return Err(HostError::Invalid(format!(
                    "{} is not in the manifest's provides",
                    input.capability_id
                )));
            }
            if input.capability_id.starts_with("desktop.") {
                let hostd = catalog::contract(&input.capability_id)
                    .is_some_and(|contract| matches!(contract.provider, Provider::Hostd(_)));
                if !hostd {
                    return Err(HostError::Invalid(format!(
                        "{} is not a hostd capability in the catalog",
                        input.capability_id
                    )));
                }
            } else if !input.capability_id.starts_with("plugin.") {
                return Err(HostError::Invalid(
                    "capabilities outside desktop.* must be plugin.*".into(),
                ));
            }
            let taken = inner.leases.values().any(|lease| {
                lease.capability_id == input.capability_id && lease.entry_id != entry_id
            });
            if taken {
                return Err(HostError::Conflict(ConflictReason::SingleProviderTaken));
            }
            // Re-registration by the same entry replaces its old lease.
            inner.leases.retain(|_, lease| {
                !(lease.capability_id == input.capability_id && lease.entry_id == entry_id)
            });
            let lease_id = ids::new(ids::LEASE);
            inner.leases.insert(
                lease_id.clone(),
                Lease {
                    entry_id: entry_id.to_string(),
                    capability_id: input.capability_id.clone(),
                    generation,
                    expires: Instant::now() + Duration::from_millis(LEASE_TTL_MS),
                },
            );
            RegisterOutput {
                lease_id,
                ttl_ms: LEASE_TTL_MS,
                generation,
            }
        };
        // Which lease a capability was bound under, per generation: a lease
        // id routes only on the connection that took it, so it is not a
        // secret, and diagnostics can tie a stale id to its generation.
        crate::log::event(
            "host.lease_registered",
            &[
                ("lease_id", &output.lease_id),
                ("capability_id", &input.capability_id),
                ("entry_id", entry_id),
                ("generation", &generation.to_string()),
            ],
        );
        if let Some(events) = self.events() {
            events.capabilities_changed("registered");
        }
        Ok(output)
    }

    pub fn revoke(&self, generation: u64, entry_id: &str, lease_id: &str) -> Result<(), HostError> {
        let removed = {
            let mut inner = self.inner.lock().expect("host state");
            if !inner.live(generation) {
                return Err(HostError::Identity);
            }
            match inner.leases.get(lease_id) {
                Some(lease) if lease.entry_id == entry_id => {
                    inner.leases.remove(lease_id).is_some()
                }
                Some(_) => return Err(HostError::Identity),
                None => false,
            }
        };
        if removed {
            if let Some(events) = self.events() {
                events.capabilities_changed("revoked");
            }
        }
        Ok(())
    }

    /// Batch renewal. A lease from an older generation is never renewed.
    pub fn renew(&self, generation: u64, input: &RenewInput) -> Result<RenewOutput, HostError> {
        let mut inner = self.inner.lock().expect("host state");
        if !inner.live(generation) {
            return Err(HostError::Identity);
        }
        let now = Instant::now();
        let mut output = RenewOutput {
            renewed: vec![],
            expired: vec![],
        };
        for lease_id in &input.lease_ids {
            match inner.leases.get_mut(lease_id) {
                Some(lease) if lease.generation == generation && lease.expires > now => {
                    lease.expires = now + Duration::from_millis(LEASE_TTL_MS);
                    output.renewed.push(lease_id.clone());
                }
                _ => output.expired.push(lease_id.clone()),
            }
        }
        Ok(output)
    }

    pub fn event(
        &self,
        generation: u64,
        entry_id: &str,
        input: EventInput,
    ) -> Result<bool, HostError> {
        let declared = {
            let inner = self.inner.lock().expect("host state");
            if !inner.live(generation) {
                return Err(HostError::Identity);
            }
            let Some(assigned) = inner.entries.get(entry_id) else {
                return Err(HostError::Identity);
            };
            if !assigned.active {
                return Err(HostError::Conflict(ConflictReason::CandidateCannotClaim));
            }
            // hostd's own marker for a dropped event queue (host protocol §7):
            // not a plugin event, so no manifest declares it.
            if input.name == RESYNC_EVENT {
                Some(EventDecl {
                    name: RESYNC_EVENT.into(),
                    schema: serde_json::json!({"type": "object"}),
                    coalesce: ditto_protocol::manifest::Coalesce::None,
                })
            } else {
                assigned
                    .events
                    .iter()
                    .find(|event| event.name == input.name)
                    .cloned()
            }
        };
        // Coalescing happens in hostd's per-entry queue; Core only refuses
        // what the manifest did not declare.
        if declared.is_none() {
            return Err(HostError::Invalid(format!(
                "event {} is not declared in the manifest",
                input.name
            )));
        }
        if let Some(events) = self.events() {
            events.host_event(entry_id, &input.name, input.payload);
        }
        Ok(true)
    }

    pub fn entry_state(&self, generation: u64, input: EntryStateInput) -> Result<(), HostError> {
        let mut newly_failed = Vec::new();
        {
            let mut inner = self.inner.lock().expect("host state");
            if !inner.live(generation) {
                return Err(HostError::Identity);
            }
            for report in input.entries {
                let was_failed = inner
                    .reports
                    .get(&report.entry_id)
                    .is_some_and(|old| old.fiber_state == FiberState::Failed);
                if report.fiber_state == FiberState::Failed
                    && !was_failed
                    && inner.entries.contains_key(&report.entry_id)
                {
                    newly_failed.push(report.entry_id.clone());
                }
                inner.reports.insert(report.entry_id.clone(), report);
            }
        }
        if let Some(events) = self.events() {
            for entry_id in newly_failed {
                events.instability(&format!("entry {entry_id} failed"));
                if self.record(&entry_id, Counter::Failed) >= ENTRY_FAILURE_LIMIT {
                    events.disable_entry(&entry_id, "failed_repeatedly");
                }
            }
        }
        Ok(())
    }

    pub fn resources(&self, generation: u64, input: ResourcesInput) -> Result<(), HostError> {
        let mut inner = self.inner.lock().expect("host state");
        if !inner.live(generation) {
            return Err(HostError::Identity);
        }
        inner.heap = Some(NodeHeap {
            heap_used: input.heap_used,
            external: input.external,
            array_buffers: input.array_buffers,
        });
        Ok(())
    }

    // ---- routing -------------------------------------------------------------

    /// Who provides `capability_id` right now, or why nobody does.
    pub fn provider(
        &self,
        capability_id: &str,
    ) -> Result<(Arc<Peer>, String, String), UnavailableReason> {
        let inner = self.inner.lock().expect("host state");
        match inner.run {
            RunState::Rescue => return Err(UnavailableReason::RescueMode),
            RunState::CrashLoop => return Err(UnavailableReason::HostCrashLoop),
            _ => {}
        }
        let Some(peer) = inner.peer.clone().filter(|peer| !peer.is_closed()) else {
            return Err(UnavailableReason::HostUnavailable);
        };
        let now = Instant::now();
        let lease = inner
            .leases
            .iter()
            .find(|(_, lease)| lease.capability_id == capability_id && lease.expires > now);
        match lease {
            Some((lease_id, lease)) => Ok((peer, lease_id.clone(), lease.entry_id.clone())),
            None => Err(UnavailableReason::NotBound),
        }
    }

    pub fn availability(
        &self,
        capability_id: &str,
    ) -> (bool, Option<UnavailableReason>, Option<String>) {
        match self.provider(capability_id) {
            Ok((_, _, entry_id)) => (true, None, Some(entry_id)),
            Err(reason) => (false, Some(reason), None),
        }
    }

    pub fn leases_of(&self, entry_id: &str) -> Vec<String> {
        let inner = self.inner.lock().expect("host state");
        let now = Instant::now();
        inner
            .leases
            .values()
            .filter(|lease| lease.entry_id == entry_id && lease.expires > now)
            .map(|lease| lease.capability_id.clone())
            .collect()
    }

    pub fn lease_count(&self) -> usize {
        self.inner.lock().expect("host state").leases.len()
    }

    pub fn entry_count(&self) -> usize {
        self.inner.lock().expect("host state").entries.len()
    }

    pub fn report(&self, entry_id: &str) -> Option<EntryStateReport> {
        self.inner
            .lock()
            .expect("host state")
            .reports
            .get(entry_id)
            .cloned()
    }

    pub fn node_version(&self) -> Option<String> {
        self.inner
            .lock()
            .expect("host state")
            .hello
            .as_ref()
            .map(|hello| hello.node_version.trim_start_matches('v').to_string())
    }

    pub fn status(&self) -> HostStatus {
        let inner = self.inner.lock().expect("host state");
        let now = Instant::now();
        let pid = inner
            .peer
            .as_ref()
            .filter(|peer| !peer.is_closed())
            .map(|peer| peer.pid);
        let mut versions = std::collections::BTreeMap::new();
        if let Some(hello) = &inner.hello {
            versions.insert("hostd".to_string(), hello.hostd_version.clone());
            versions.insert("node".to_string(), hello.node_version.clone());
            versions.insert("cordis".to_string(), hello.cordis_version.clone());
            versions.insert("vendor".to_string(), hello.vendor_fingerprint.clone());
        }
        HostStatus {
            state: inner.run.label().into(),
            generation: (inner.generation > 0).then_some(inner.generation),
            restarts_last_10_min: inner
                .restarts
                .iter()
                .filter(|at| now.duration_since(**at) <= CRASH_LOOP_WINDOW)
                .count() as u32,
            process: pid.map(read_process),
            heap: inner.heap.clone(),
            strategy: inner.hello.as_ref().map(|hello| {
                serde_json::to_value(hello.strategy)
                    .ok()
                    .and_then(|v| v.as_str().map(String::from))
                    .unwrap_or_default()
            }),
            versions,
        }
    }
}

fn terminate(pid: u32) {
    // An in-process peer (a test over a socket pair) reports Core's own PID;
    // Core never signals itself.
    if pid == std::process::id() || pid <= 1 {
        return;
    }
    // SIGTERM, then SIGKILL after a second (plan/03/02 §12).
    // SAFETY: kill has no memory preconditions; a stale pid only fails.
    unsafe { libc::kill(pid as i32, libc::SIGTERM) };
    std::thread::spawn(move || {
        std::thread::sleep(Duration::from_secs(1));
        // SAFETY: as above.
        unsafe { libc::kill(pid as i32, libc::SIGKILL) };
    });
}

/// Process figures Core reads itself from `/proc`; hostd's report is never
/// used for these (RUN-08, NFR-15).
pub fn read_process(pid: u32) -> ProcessResources {
    let field = |text: &str, name: &str| -> Option<u64> {
        text.lines()
            .find(|line| line.starts_with(name))
            .and_then(|line| line.split_whitespace().nth(1))
            .and_then(|value| value.parse().ok())
    };
    let rollup = std::fs::read_to_string(format!("/proc/{pid}/smaps_rollup")).unwrap_or_default();
    let status = std::fs::read_to_string(format!("/proc/{pid}/status")).unwrap_or_default();
    let stat = std::fs::read_to_string(format!("/proc/{pid}/stat")).unwrap_or_default();
    let cpu_ticks = stat
        .rsplit_once(')')
        .map(|(_, rest)| rest.split_whitespace().collect::<Vec<_>>())
        .and_then(|fields| {
            let user: u64 = fields.get(11)?.parse().ok()?;
            let system: u64 = fields.get(12)?.parse().ok()?;
            Some(user + system)
        });
    ProcessResources {
        pid,
        pss_kib: field(&rollup, "Pss:"),
        rss_kib: field(&status, "VmRSS:"),
        threads: field(&status, "Threads:").map(|value| value as u32),
        fds: std::fs::read_dir(format!("/proc/{pid}/fd"))
            .ok()
            .map(|dir| dir.count() as u32),
        cpu_ticks,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_dropped_connection_is_fenced_until_the_next_hostd_attaches() {
        let hosts = HostManager::new(
            None,
            None,
            Arc::new(IdentityRegistry::new()),
            "/nonexistent/core.sock".into(),
            false,
        );
        hosts.set_needed(true);
        let (sink, _outgoing) = std::sync::mpsc::channel();
        let generation = hosts.attach(Arc::new(Peer::new(
            "conn-1".into(),
            "hostd".into(),
            0,
            sink,
        )));
        assert_eq!(hosts.heartbeat(generation), Ok(()));
        // The heartbeat lapsed: Core drops the connection, then the process
        // exits and its connection closes as well.
        hosts.detach(generation, "heartbeat_timeout");
        hosts.detach(generation, "connection_closed");
        assert_eq!(
            hosts.status().restarts_last_10_min,
            1,
            "one loss, counted once"
        );
        // Whatever the old connection still sends counts for nothing, even
        // before another hostd attaches.
        assert_eq!(hosts.heartbeat(generation), Err(HostError::Identity));
        assert_eq!(
            hosts.renew(
                generation,
                &RenewInput {
                    lease_ids: vec!["lease-old".into()]
                }
            ),
            Err(HostError::Identity)
        );
        assert!(!hosts.validate(generation, "ent-1"));
    }
}
