//! The process-wide state of a running Core and the single coordinator thread
//! that owns the only writing store connection (D-26 proposal: std threads, one
//! coordinator, a small pool of read-only connections). Every write queues
//! here, which is also what serializes commits to one configuration (CHG-05).

use std::{
    collections::{HashMap, VecDeque},
    path::PathBuf,
    sync::{
        atomic::{AtomicBool, AtomicU64, Ordering},
        mpsc::{self, Sender},
        Arc, Mutex,
    },
    thread,
    time::{Duration, Instant},
};

use ditto_protocol::{rpc::CoreMode, DesktopEventPayload, Subject};
use ditto_store::{Paths, Store, StoreError, StoreResult, WriterLock};
use ditto_system::SystemServices;
use rusqlite::Connection;

use crate::{
    coordinator::Coordinator,
    hosts::{HostEvents, HostManager},
    identity::IdentityRegistry,
    launcher::{Quota, Specification},
    participants::CompositorParticipant,
    session::Session,
    shell::ShellManager,
};

pub struct CoreConfig {
    pub agent: Option<Specification>,
    /// The Agent's model backend, launched confined by Core (G2-PLAT-04).
    pub agent_backend: Option<crate::agent_backend::BackendSpecification>,
    pub agent_idle: std::time::Duration,
    pub paths: Paths,
    pub mode: CoreMode,
    pub socket: PathBuf,
    pub shell: Option<Specification>,
    pub hostd: Option<Specification>,
    pub rescue_ui: Option<Specification>,
    pub lock: Option<Specification>,
    /// Directory of built-in `.dittopkg` files installed at first start.
    pub builtin_packages: Option<PathBuf>,
    /// Re-hash package trees at preflight (MOD-04); tests may turn it off.
    pub verify_trees: bool,
    /// How long boot recovery waits for participants (plan/03/02 §13).
    pub recovery_wait_shell: Duration,
    pub recovery_wait_host: Duration,
    /// Observation period before a commit becomes last-known-good (D-15: 60 s).
    pub observation_period: Duration,
    pub confirmation_window: Duration,
    /// How long after an output disappears Core reads the windows back
    /// (crate::outputs::SETTLE); tests shorten it.
    pub output_settle: Duration,
}

impl CoreConfig {
    pub fn new(paths: Paths, socket: PathBuf) -> Self {
        Self {
            agent: None,
            agent_backend: None,
            agent_idle: crate::agent_manager::IDLE,
            paths,
            mode: CoreMode::Normal,
            socket,
            shell: None,
            hostd: None,
            rescue_ui: None,
            lock: None,
            builtin_packages: None,
            verify_trees: true,
            recovery_wait_shell: Duration::from_secs(10),
            recovery_wait_host: Duration::from_secs(15),
            observation_period: Duration::from_secs(60),
            confirmation_window: Duration::from_secs(15),
            output_settle: crate::outputs::SETTLE,
        }
    }
}

/// One unit of coordinator work: runs on the coordinator thread, in order.
pub type Work = Box<dyn FnOnce(&mut Coordinator) + Send>;

#[derive(Clone, Debug, PartialEq)]
pub enum CoordinateError {
    /// The coordinator did not finish within the caller's deadline; the work
    /// is still queued or running and will complete.
    Timeout,
    Stopped,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct LockState {
    pub locked: bool,
    pub client_running: bool,
}

#[derive(Default)]
struct LockClient {
    child: Option<std::process::Child>,
    failures: VecDeque<Instant>,
    retry_at: Option<Instant>,
    stopped: bool,
}

impl LockClient {
    fn reset_failures(&mut self) {
        self.failures.clear();
        self.retry_at = None;
        self.stopped = false;
    }

    fn failed(&mut self, now: Instant) {
        use crate::shell::{SHELL_FAILURE_LIMIT, SHELL_FAILURE_WINDOW, SHELL_RESTART_BACKOFF};
        self.failures
            .retain(|at| now.duration_since(*at) <= SHELL_FAILURE_WINDOW);
        self.failures.push_back(now);
        if self.failures.len() >= SHELL_FAILURE_LIMIT {
            // Latched: time alone must not restart a repeatedly broken lock UI.
            // Recovery is an explicit lock request or compositor reconnection.
            // Neither this latch nor recovery clears Core's locked bit.
            self.stopped = true;
            self.retry_at = None;
            crate::log::event(
                "lock.restart_stopped",
                &[
                    ("reason_code", "failure_limit"),
                    ("failure_count", &self.failures.len().to_string()),
                    ("recovery", "compositor_reconnected_or_lock_requested"),
                ],
            );
        } else {
            let delay = SHELL_RESTART_BACKOFF[self.failures.len() - 1];
            self.retry_at = Some(now + Duration::from_secs(delay));
            crate::log::event(
                "lock.restart_scheduled",
                &[
                    ("reason_code", "client_failure"),
                    ("failure_count", &self.failures.len().to_string()),
                    ("backoff_seconds", &delay.to_string()),
                ],
            );
        }
    }

    fn ready(&self, now: Instant) -> bool {
        !self.stopped && self.retry_at.is_none_or(|at| at <= now)
    }
}

#[derive(Clone, Debug)]
pub struct SubscriptionInfo {
    pub subject: Subject,
    pub topics: Vec<ditto_protocol::EventTopic>,
    pub connection_id: String,
}

pub struct Core {
    pub agent: Arc<crate::agent_manager::AgentManager>,
    /// Context attached to messages; memory only (G2-CORE-03).
    pub contexts: crate::context::ContextBroker,
    /// Trusted background jobs (G2-CORE-05).
    pub jobs: crate::jobs_pool::JobPool,
    pub agent_storage_ready: bool,
    pub session: Arc<Session>,
    pub paths: Paths,
    pub mode: CoreMode,
    pub hosts: Arc<HostManager>,
    pub shell: Arc<ShellManager>,
    pub compositor: Arc<CompositorParticipant>,
    pub system: Arc<dyn SystemServices>,
    pub registry: Arc<IdentityRegistry>,
    pub config: CoreConfigShared,
    work: Mutex<Sender<Work>>,
    recovering: AtomicBool,
    pub lock: Mutex<LockState>,
    instability: Mutex<Vec<(Instant, String)>>,
    pub subscriptions: Mutex<HashMap<String, SubscriptionInfo>>,
    pub policy_fallbacks: AtomicU64,
    readers: Mutex<Vec<Store>>,
    connections: AtomicU64,
    pub lock_spec: Option<Specification>,
    lock_client: Mutex<LockClient>,
}

/// The parts of the configuration the coordinator reads while running.
#[derive(Clone)]
pub struct CoreConfigShared {
    pub verify_trees: bool,
    pub recovery_wait_shell: Duration,
    pub recovery_wait_host: Duration,
    pub observation_period: Duration,
    pub confirmation_window: Duration,
    pub socket: PathBuf,
}

struct Events(std::sync::Weak<Core>);

impl HostEvents for Events {
    fn host_ready(&self, _generation: u64) {
        if let Some(core) = self.0.upgrade() {
            core.submit(|coordinator| {
                coordinator.sync_participant(ditto_protocol::participant::ParticipantRole::Hostd)
            });
            core.publish(DesktopEventPayload::CapabilitiesChanged {
                reason: "host_ready".into(),
            });
        }
    }

    fn host_lost(&self, _generation: u64, reason: &str) {
        if let Some(core) = self.0.upgrade() {
            crate::log::event(
                "host.lost",
                &[(
                    "reason_code",
                    match reason {
                        "connection_closed" => "connection_closed",
                        "heartbeat_timeout" => "heartbeat_timeout",
                        _ => "unknown",
                    },
                )],
            );
            // Anything that followed tasks events rebuilds from a snapshot
            // once a provider is back.
            core.resync_topic(ditto_protocol::EventTopic::Tasks, "host_unavailable");
        }
    }

    fn capabilities_changed(&self, reason: &str) {
        if let Some(core) = self.0.upgrade() {
            core.publish(DesktopEventPayload::CapabilitiesChanged {
                reason: reason.into(),
            });
        }
    }

    fn host_event(&self, entry_id: &str, name: &str, payload: serde_json::Value) {
        if let Some(core) = self.0.upgrade() {
            if name == crate::hosts::RESYNC_EVENT {
                // Events were lost inside hostd; whoever follows them must
                // rebuild from a snapshot rather than miss changes silently.
                core.resync_topic(ditto_protocol::EventTopic::Tasks, "host_queue_overflow");
                core.resync_topic(ditto_protocol::EventTopic::Plugins, "host_queue_overflow");
                return;
            }
            core.publish(DesktopEventPayload::HostEvent {
                entry_id: entry_id.into(),
                name: name.into(),
                payload,
            });
        }
    }

    fn disable_entry(&self, entry_id: &str, reason: &str) {
        if let Some(core) = self.0.upgrade() {
            let (entry_id, reason) = (entry_id.to_string(), reason.to_string());
            core.submit(move |coordinator| coordinator.supervisor_disable(&entry_id, &reason));
        }
    }

    fn instability(&self, what: &str) {
        if let Some(core) = self.0.upgrade() {
            core.note_instability(what);
        }
    }
}

impl Core {
    /// Open the store (quick check, backup, migration), then start the
    /// coordinator. A store that fails its check is not repaired: the error
    /// goes back to the caller, which starts rescue mode.
    pub fn start(
        config: CoreConfig,
        session: Arc<Session>,
        system: Arc<dyn SystemServices>,
        registry: Arc<IdentityRegistry>,
    ) -> StoreResult<Arc<Core>> {
        let lock = WriterLock::acquire(&config.paths.lock())?;
        let (mut store, report) = Store::open_writer(&config.paths, &lock)?;
        let agent_storage_ready = ditto_store::conversations::recover(&mut store)
            .and_then(|_| ditto_store::turns::interrupt_connection(&mut store, None))
            .is_ok();
        if !agent_storage_ready {
            crate::log::event("agent.storage_unavailable", &[]);
        }
        let rescue = config.mode == CoreMode::Rescue;
        let hosts = Arc::new(HostManager::new(
            config.hostd.clone(),
            Some(Quota::service()),
            Arc::clone(&registry),
            config.socket.clone(),
            rescue,
        ));
        let shell = Arc::new(ShellManager::new(
            config.shell.clone(),
            config.rescue_ui.clone(),
            Arc::clone(&registry),
            config.socket.clone(),
        ));
        let compositor = Arc::new(CompositorParticipant::new(Arc::clone(&session)));
        let (sender, receiver) = mpsc::channel::<Work>();
        let core = Arc::new(Core {
            agent: Arc::new(
                crate::agent_manager::AgentManager::new(
                    config.agent.clone(),
                    config.agent_backend.clone(),
                    Arc::clone(&registry),
                    config.socket.clone(),
                    config.paths.state.join("agent"),
                )
                .with_idle(config.agent_idle),
            ),
            contexts: crate::context::ContextBroker::default(),
            // Fixture kinds (CPU loop, memory hog) only in test runs.
            jobs: crate::jobs_pool::JobPool::new(
                std::env::var("DITTO_SYSTEM").is_ok_and(|v| v == "none")
                    || std::env::var("DITTO_TEST_FIXTURE").is_ok_and(|v| v == "1"),
            ),
            agent_storage_ready,
            session,
            paths: config.paths.clone(),
            mode: config.mode,
            hosts: Arc::clone(&hosts),
            shell,
            compositor,
            system,
            registry,
            config: CoreConfigShared {
                verify_trees: config.verify_trees,
                recovery_wait_shell: config.recovery_wait_shell,
                recovery_wait_host: config.recovery_wait_host,
                observation_period: config.observation_period,
                confirmation_window: config.confirmation_window,
                socket: config.socket.clone(),
            },
            work: Mutex::new(sender),
            recovering: AtomicBool::new(true),
            lock: Mutex::new(LockState::default()),
            instability: Mutex::new(Vec::new()),
            subscriptions: Mutex::new(HashMap::new()),
            policy_fallbacks: AtomicU64::new(0),
            readers: Mutex::new(Vec::new()),
            connections: AtomicU64::new(0),
            lock_spec: config.lock.clone(),
            lock_client: Mutex::new(LockClient::default()),
        });
        hosts.set_events(Arc::new(Events(Arc::downgrade(&core))));
        crate::outputs::install(&core, config.output_settle);
        crate::jobs_pool::install(&core);
        // Region rules follow windows that open later (D-40). On its own
        // thread: the compositor event pump never waits on placement.
        let compositor = Arc::clone(&core.compositor);
        core.session.set_windows_opened(Arc::new(move |opened| {
            let compositor = Arc::clone(&compositor);
            let _ = std::thread::Builder::new()
                .name("ditto-regions".into())
                .spawn(move || {
                    for window in &opened {
                        compositor.window_opened(window);
                    }
                });
        }));
        let coordinator_core = Arc::clone(&core);
        let builtin = config.builtin_packages.clone();
        thread::Builder::new()
            .name("ditto-coordinator".into())
            .spawn(move || {
                let _lock = lock;
                let mut coordinator = Coordinator::new(coordinator_core, store, report);
                coordinator.boot(builtin.as_deref());
                coordinator.run(receiver);
            })
            .map_err(|error| StoreError::Io(error.to_string()))?;
        let supervisor = Arc::clone(&core);
        thread::Builder::new()
            .name("ditto-supervision".into())
            .spawn(move || loop {
                thread::sleep(Duration::from_millis(250));
                supervisor.supervise();
            })
            .map_err(|error| StoreError::Io(error.to_string()))?;
        Ok(core)
    }

    pub fn next_connection_id(&self) -> String {
        format!(
            "conn-{}",
            self.connections.fetch_add(1, Ordering::SeqCst) + 1
        )
    }

    pub fn is_recovering(&self) -> bool {
        self.recovering.load(Ordering::SeqCst)
    }

    pub(crate) fn finish_recovery(&self) {
        self.recovering.store(false, Ordering::SeqCst);
    }

    /// Queue work for the coordinator without waiting.
    pub fn submit(&self, work: impl FnOnce(&mut Coordinator) + Send + 'static) {
        let _ = self
            .work
            .lock()
            .expect("coordinator queue")
            .send(Box::new(work));
    }

    /// Run work on the coordinator and wait for its result, at most `timeout`.
    pub fn coordinate<T: Send + 'static>(
        &self,
        timeout: Duration,
        work: impl FnOnce(&mut Coordinator) -> T + Send + 'static,
    ) -> Result<T, CoordinateError> {
        let (reply, answer) = mpsc::channel();
        let sent = self.work.lock().expect("coordinator queue").send(Box::new(
            move |coordinator: &mut Coordinator| {
                let _ = reply.send(work(coordinator));
            },
        ));
        if sent.is_err() {
            return Err(CoordinateError::Stopped);
        }
        answer.recv_timeout(timeout).map_err(|error| match error {
            mpsc::RecvTimeoutError::Timeout => CoordinateError::Timeout,
            mpsc::RecvTimeoutError::Disconnected => CoordinateError::Stopped,
        })
    }

    /// A read-only query on a pooled connection, never queued behind a write.
    pub fn read<T>(&self, query: impl FnOnce(&Connection) -> StoreResult<T>) -> StoreResult<T> {
        let reader = self.readers.lock().expect("reader pool").pop();
        let reader = match reader {
            Some(reader) => reader,
            None => Store::open_reader(&self.paths)?,
        };
        let outcome = query(reader.connection());
        let mut pool = self.readers.lock().expect("reader pool");
        if pool.len() < 4 {
            pool.push(reader);
        }
        outcome
    }

    pub fn publish(&self, payload: DesktopEventPayload) {
        self.session.publish_event(payload);
    }

    /// End every subscription that includes `topic` with `resync_required`.
    pub fn resync_topic(&self, topic: ditto_protocol::EventTopic, reason: &str) {
        let affected: Vec<String> = self
            .subscriptions
            .lock()
            .expect("subscriptions")
            .iter()
            .filter(|(_, info)| info.topics.contains(&topic))
            .map(|(id, _)| id.clone())
            .collect();
        for subscription in affected {
            self.session.require_resync(&subscription, reason);
        }
    }

    /// End the subscriptions an entry held once it no longer runs.
    pub fn close_subscriptions_of(&self, subject: &Subject, reason: &str) {
        let affected: Vec<String> = {
            let mut subscriptions = self.subscriptions.lock().expect("subscriptions");
            let affected: Vec<String> = subscriptions
                .iter()
                .filter(|(_, info)| &info.subject == subject)
                .map(|(id, _)| id.clone())
                .collect();
            for id in &affected {
                subscriptions.remove(id);
            }
            affected
        };
        for subscription in affected {
            self.session.require_resync(&subscription, reason);
        }
    }

    pub fn note_instability(&self, what: &str) {
        let mut instability = self.instability.lock().expect("instability");
        instability.push((Instant::now(), what.to_string()));
        let horizon = Instant::now() - Duration::from_secs(600);
        instability.retain(|(at, _)| *at > horizon);
    }

    /// Whether anything unstable happened after `since`.
    pub fn unstable_since(&self, since: Instant) -> Option<String> {
        self.instability
            .lock()
            .expect("instability")
            .iter()
            .find(|(at, _)| *at >= since)
            .map(|(_, what)| what.clone())
    }

    pub fn session_locked(&self) -> bool {
        self.lock.lock().expect("lock state").locked
    }

    /// Start the lock client (D-30: a separate process, not a slot).
    /// A new request resets a stopped retry budget, but never unlocks.
    pub fn lock_session(&self) -> bool {
        let mut client = self.lock_client.lock().expect("lock client");
        self.lock.lock().expect("lock state").locked = true;
        client.reset_failures();
        let started = self.start_lock_client(&mut client, Instant::now());
        self.publish_lock_state();
        started
    }

    /// Called from the existing compositor reconnect path, even if its offline
    /// interval was shorter than a supervision tick. Use Session's authority;
    /// no second reachability probe or polling loop is needed.
    pub fn compositor_reconnected(&self) {
        let mut client = self.lock_client.lock().expect("lock client");
        client.reset_failures();
        let before = self.lock.lock().expect("lock state").clone();
        self.start_lock_client(&mut client, Instant::now());
        if *self.lock.lock().expect("lock state") != before {
            self.publish_lock_state();
        }
    }

    // The client guard serializes lock requests, reconnection and supervision:
    // only supervision reaps a child, so no exit status can be discarded by a
    // concurrent request. Spawn failures use the same bounded retry budget.
    fn start_lock_client(&self, client: &mut LockClient, now: Instant) -> bool {
        if client.child.is_some() {
            return true;
        }
        if !self.session_locked() || !self.session.is_online() || !client.ready(now) {
            return false;
        }
        let Some(spec) = &self.lock_spec else {
            return false;
        };
        match crate::launcher::launch_parsed(&self.registry, spec, &self.config.socket, None, &[]) {
            Ok(started) => {
                client.child = Some(started);
                client.retry_at = None;
                self.lock.lock().expect("lock state").client_running = true;
                true
            }
            Err(error) => {
                crate::log::event(
                    "lock.start_failed",
                    &[
                        ("reason", &error.to_string()),
                        ("reason_code", crate::log::io_error_code(error.kind())),
                    ],
                );
                client.failed(now);
                false
            }
        }
    }

    fn publish_lock_state(&self) {
        let state = self.session_state();
        self.system
            .set_lock_state(state.locked, state.lock_client_running);
        self.publish(DesktopEventPayload::SessionChanged { state });
    }

    pub fn session_state(&self) -> ditto_protocol::services::SessionState {
        let lock = self.lock.lock().expect("lock state").clone();
        let mut state =
            self.system
                .session_state()
                .unwrap_or(ditto_protocol::services::SessionState {
                    locked: false,
                    lock_client_running: false,
                    preparing_for_sleep: false,
                    logind_available: false,
                });
        state.locked = lock.locked;
        state.lock_client_running = lock.client_running;
        state
    }

    /// Supervision every 250 ms: hostd heartbeat and leases, Shell restarts,
    /// the lock client, subscriptions of closed connections.
    fn supervise(&self) {
        if let Some(connection) = self.agent.tick() {
            self.submit(move |c| {
                let _ = ditto_store::conversations::release_connection(c.store(), &connection);
                let _ = ditto_store::turns::interrupt_connection(c.store(), Some(&connection));
            });
        }
        if let Some(generation) = self.hosts.tick() {
            self.hosts.detach(generation, "heartbeat_timeout");
        }
        if self.shell.tick() {
            self.note_instability("shell exited");
        }
        let mut client = self.lock_client.lock().expect("lock client");
        self.supervise_lock(&mut client, Instant::now());
    }

    fn supervise_lock(&self, client: &mut LockClient, now: Instant) {
        let before = self.lock.lock().expect("lock state").clone();
        if let Some(Ok(Some(status))) = client.child.as_mut().map(|child| child.try_wait()) {
            crate::log::process_exit("lock.exited", status);
            client.child = None;
            self.lock.lock().expect("lock state").client_running = false;
            if status.success() {
                // The lock client exits 0 only after PAM accepted the user.
                self.lock.lock().expect("lock state").locked = false;
                client.reset_failures();
            } else {
                // Crashed or killed: remain locked throughout backoff, offline
                // suspension and the failure-limit latch (SEC-08).
                client.failed(now);
            }
        }
        self.start_lock_client(client, now);
        if *self.lock.lock().expect("lock state") != before {
            self.publish_lock_state();
        }
    }
}

#[cfg(test)]
mod lock_supervision_tests {
    use super::*;

    fn fixture_with_spec(spec: Option<Specification>) -> (Arc<Core>, PathBuf) {
        let root =
            std::env::temp_dir().join(format!("lock-supervision-{}", ditto_protocol::ids::ulid()));
        std::fs::create_dir_all(&root).unwrap();
        let mut config = CoreConfig::new(Paths::under(&root), root.join("core.sock"));
        config.mode = CoreMode::Rescue;
        config.lock = spec;
        config.recovery_wait_shell = Duration::ZERO;
        config.recovery_wait_host = Duration::ZERO;
        let (adapter, _) = ditto_compositor::fixture::FixtureCompositor::paired();
        let core = Core::start(
            config,
            Arc::new(Session::new(Box::new(adapter))),
            Arc::new(ditto_system::fake::FakeSystem::default()),
            Arc::new(IdentityRegistry::new()),
        )
        .unwrap();
        core.coordinate(Duration::from_secs(5), |_| ()).unwrap();
        (core, root)
    }

    fn fixture() -> (Arc<Core>, PathBuf) {
        fixture_with_spec(None)
    }

    fn missing_spec() -> Specification {
        crate::launcher::parse("lock 0.3.1 /nonexistent-ditto-lock-fixture").unwrap()
    }

    fn crashed_child() -> std::process::Child {
        let mut child = std::process::Command::new("/bin/sleep")
            .arg("30")
            .spawn()
            .unwrap();
        child.kill().unwrap();
        child.wait().unwrap();
        child
    }

    #[test]
    fn signal_failure_schedules_backoff_and_keeps_session_locked() {
        let (core, root) = fixture();
        // Holding the same guard as supervision makes the clock deterministic
        // even while Core's normal supervisor thread is running.
        let mut client = core.lock_client.lock().unwrap();
        core.lock.lock().unwrap().locked = true;
        core.lock.lock().unwrap().client_running = true;
        client.child = Some(crashed_child());
        let now = Instant::now();
        core.supervise_lock(&mut client, now);
        assert_eq!(client.retry_at, Some(now + Duration::from_secs(1)));
        assert_eq!(client.failures.len(), 1);
        assert!(core.session_state().locked);
        assert!(!core.session_state().lock_client_running);
        drop(client);
        std::fs::remove_dir_all(root).unwrap();
    }
    #[test]
    fn consecutive_crashes_back_off_stop_and_stay_locked_until_a_new_request() {
        let (core, root) = fixture();
        let mut client = core.lock_client.lock().unwrap();
        core.lock.lock().unwrap().locked = true;
        let mut now = Instant::now();
        for failure in 1..=3 {
            client.child = Some(crashed_child());
            core.lock.lock().unwrap().client_running = true;
            core.supervise_lock(&mut client, now);
            assert_eq!(client.failures.len(), failure);
            assert!(core.session_state().locked);
            assert!(!core.session_state().lock_client_running);
            let system_state = core.system.session_state().unwrap();
            assert!(system_state.locked);
            assert!(!system_state.lock_client_running);
            if failure < 3 {
                let deadline = now + Duration::from_secs(failure as u64);
                assert_eq!(client.retry_at, Some(deadline));
                assert!(!client.ready(deadline - Duration::from_nanos(1)));
                core.supervise_lock(&mut client, deadline - Duration::from_nanos(1));
                assert!(client.child.is_none());
                assert!(client.ready(deadline));
                now = deadline;
            }
        }
        assert!(client.stopped);
        assert!(!client.ready(now + Duration::from_secs(3600)));
        core.supervise_lock(&mut client, now + Duration::from_secs(3600));
        assert!(client.child.is_none());
        assert!(core.session_locked());
        drop(client);
        assert!(!core.lock_session()); // Missing UI cannot unlock either.
        let client = core.lock_client.lock().unwrap();
        assert!(client.failures.is_empty());
        assert!(!client.stopped);
        assert!(core.session_locked());
        drop(client);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn offline_session_pauses_retries_and_reconnection_resets_a_stopped_budget() {
        let (core, root) = fixture_with_spec(Some(missing_spec()));
        core.session.mark_offline("fixture_disconnect");
        assert!(!core.lock_session());
        let mut client = core.lock_client.lock().unwrap();
        let now = Instant::now();
        for step in [0, 1, 3, 3600] {
            core.supervise_lock(&mut client, now + Duration::from_secs(step));
        }
        // An attempted launch would fail canonicalization and consume a retry.
        assert!(client.failures.is_empty());
        assert!(core.session_state().locked);
        client.child = Some(crashed_child());
        core.supervise_lock(&mut client, now);
        core.supervise_lock(&mut client, now + Duration::from_secs(1));
        assert_eq!(client.failures.len(), 1); // Reap while offline, no restart.
        client.failed(now);
        client.failed(now);
        assert!(client.stopped);
        drop(client);
        let (adapter, _) = ditto_compositor::fixture::FixtureCompositor::paired();
        core.session.reconnect(Box::new(adapter)).unwrap();
        core.compositor_reconnected();
        let client = core.lock_client.lock().unwrap();
        assert!(!client.stopped);
        // Reconnection tried once. No binary exists, so it starts a fresh budget.
        assert_eq!(client.failures.len(), 1);
        assert!(client.retry_at.is_some());
        assert!(core.session_state().locked);
        drop(client);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn launch_errors_also_back_off_and_stop_at_the_failure_limit() {
        let (core, root) = fixture_with_spec(Some(missing_spec()));
        assert!(!core.lock_session());
        let mut client = core.lock_client.lock().unwrap();
        assert_eq!(client.failures.len(), 1);
        let first_deadline = client.retry_at.unwrap();
        core.supervise_lock(&mut client, first_deadline - Duration::from_nanos(1));
        assert_eq!(client.failures.len(), 1);
        core.supervise_lock(&mut client, first_deadline);
        assert_eq!(client.failures.len(), 2);
        let second_deadline = client.retry_at.unwrap();
        assert_eq!(second_deadline, first_deadline + Duration::from_secs(2));
        core.supervise_lock(&mut client, second_deadline);
        assert_eq!(client.failures.len(), 3);
        assert!(client.stopped);
        core.supervise_lock(&mut client, second_deadline + Duration::from_secs(3600));
        assert_eq!(client.failures.len(), 3);
        assert!(core.session_locked());
        drop(client);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn only_zero_exit_unlocks_even_when_compositor_is_offline() {
        let (core, root) = fixture();
        let mut client = core.lock_client.lock().unwrap();
        core.lock.lock().unwrap().locked = true;
        core.session.mark_offline("fixture_disconnect");
        for code in [17, 0] {
            let mut child = std::process::Command::new("/bin/sh")
                .args(["-c", &format!("exit {code}")])
                .spawn()
                .unwrap();
            assert_eq!(child.wait().unwrap().code(), Some(code));
            client.child = Some(child);
            core.lock.lock().unwrap().client_running = true;
            core.supervise_lock(&mut client, Instant::now());
            assert_eq!(core.session_locked(), code != 0);
            assert!(!core.session_state().lock_client_running);
            assert_eq!(core.system.session_state().unwrap().locked, code != 0);
        }
        assert!(client.failures.is_empty());
        drop(client);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn old_failures_age_out_before_the_limit_is_reached() {
        let mut client = LockClient::default();
        let now = Instant::now();
        client.failed(now);
        client.failed(now + crate::shell::SHELL_FAILURE_WINDOW + Duration::from_secs(1));
        assert_eq!(client.failures.len(), 1);
        assert!(!client.stopped);
        assert_eq!(
            client.retry_at,
            Some(now + crate::shell::SHELL_FAILURE_WINDOW + Duration::from_secs(2))
        );
    }

    #[test]
    fn reconnect_does_not_start_a_lock_client_for_an_unlocked_session() {
        let (core, root) = fixture_with_spec(Some(missing_spec()));
        core.compositor_reconnected();
        let client = core.lock_client.lock().unwrap();
        assert!(client.child.is_none());
        assert!(client.failures.is_empty());
        assert!(!core.session_locked());
        drop(client);
        std::fs::remove_dir_all(root).unwrap();
    }
    #[test]
    fn controlled_lock_restarts_after_backoff_and_reconnect_then_unlocks_on_zero() {
        let spec = crate::launcher::parse("lock 0.3.1 /bin/sh -c unused").unwrap();
        let spec = Specification {
            arguments: vec![
                "-c".into(),
                "read -r token <&3; kill -STOP $$; exit 0".into(),
            ],
            ..spec
        };
        let (core, root) = fixture_with_spec(Some(spec));
        assert!(core.lock_session(), "controlled lock launch failed");
        let mut client = core.lock_client.lock().unwrap();
        let mut now = Instant::now();
        for failure in 1..=3 {
            let child = client.child.as_mut().unwrap();
            child.kill().unwrap();
            child.wait().unwrap();
            core.supervise_lock(&mut client, now);
            assert!(core.session_locked());
            assert!(client.child.is_none());
            assert_eq!(client.failures.len(), failure);
            if failure < 3 {
                let deadline = client.retry_at.unwrap();
                core.supervise_lock(&mut client, deadline - Duration::from_nanos(1));
                assert!(client.child.is_none());
                core.supervise_lock(&mut client, deadline);
                assert!(client.child.is_some());
                assert!(core.session_state().lock_client_running);
                now = deadline;
            }
        }
        assert!(client.stopped);
        core.supervise_lock(&mut client, now + Duration::from_secs(3600));
        assert!(client.child.is_none());
        core.session.mark_offline("fixture_disconnect");
        core.supervise_lock(&mut client, now + Duration::from_secs(3601));
        assert!(client.child.is_none());
        assert!(core.session_locked());
        drop(client);
        let (adapter, _) = ditto_compositor::fixture::FixtureCompositor::paired();
        core.session.reconnect(Box::new(adapter)).unwrap();
        core.compositor_reconnected();
        let mut client = core.lock_client.lock().unwrap();
        assert!(client.failures.is_empty());
        assert!(!client.stopped);
        assert!(core.session_locked());
        let child = client.child.as_mut().unwrap();
        let deadline = Instant::now() + Duration::from_secs(3);
        loop {
            let stat = std::fs::read_to_string(format!("/proc/{}/stat", child.id())).unwrap();
            if stat.rsplit_once(')').unwrap().1.split_whitespace().next() == Some("T") {
                break;
            }
            assert!(Instant::now() < deadline, "lock fixture never stopped");
            std::thread::sleep(Duration::from_millis(10));
        }
        // SAFETY: this is our child, stopped after reading its launcher token.
        assert_eq!(unsafe { libc::kill(child.id() as i32, libc::SIGCONT) }, 0);
        assert!(child.wait().unwrap().success());
        core.supervise_lock(&mut client, Instant::now());
        assert!(!core.session_locked());
        assert!(!core.session_state().lock_client_running);
        drop(client);
        std::fs::remove_dir_all(root).unwrap();
    }
}
