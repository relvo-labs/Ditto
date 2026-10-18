//! The process-wide state of a running Core and the single coordinator thread
//! that owns the only writing store connection (D-26 proposal: std threads, one
//! coordinator, a small pool of read-only connections). Every write queues
//! here, which is also what serializes commits to one configuration (CHG-05).

use std::{
    collections::HashMap,
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

#[derive(Clone, Debug, Default)]
pub struct LockState {
    pub locked: bool,
    pub client_running: bool,
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
    lock_child: Mutex<Option<std::process::Child>>,
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
            lock_child: Mutex::new(None),
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

    /// Start the lock client (D-30 proposal: a separate process, not a slot).
    /// The compositor keeps the session locked if it dies (C-19 decides
    /// whether that holds on Wayfire); Core starts a new one right away.
    pub fn lock_session(&self) -> bool {
        {
            let mut state = self.lock.lock().expect("lock state");
            state.locked = true;
        }
        let started = self.start_lock_client();
        self.system.set_lock_state(true, started);
        self.publish(DesktopEventPayload::SessionChanged {
            state: self.session_state(),
        });
        started
    }

    fn start_lock_client(&self) -> bool {
        let Some(spec) = &self.lock_spec else {
            return false;
        };
        let mut child = self.lock_child.lock().expect("lock child");
        if child
            .as_mut()
            .is_some_and(|child| child.try_wait().ok().flatten().is_none())
        {
            return true;
        }
        match crate::launcher::launch_parsed(&self.registry, spec, &self.config.socket, None, &[]) {
            Ok(started) => {
                *child = Some(started);
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
                false
            }
        }
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
        let exited = {
            let mut child = self.lock_child.lock().expect("lock child");
            match child.as_mut().map(|child| child.try_wait()) {
                Some(Ok(Some(status))) => {
                    *child = None;
                    Some(status.success())
                }
                _ => None,
            }
        };
        if let Some(unlocked) = exited {
            if unlocked {
                // The lock client exits 0 only after PAM accepted the user.
                {
                    let mut state = self.lock.lock().expect("lock state");
                    state.locked = false;
                    state.client_running = false;
                }
                self.system.set_lock_state(false, false);
            } else {
                // Crashed or killed: the session stays locked; start another.
                self.lock.lock().expect("lock state").client_running = false;
                self.start_lock_client();
            }
            self.publish(DesktopEventPayload::SessionChanged {
                state: self.session_state(),
            });
        }
    }
}
