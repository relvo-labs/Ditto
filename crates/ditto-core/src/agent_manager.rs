//! One Core-supervised Agent controller. Desktop hostd is deliberately absent
//! from this manager: draining or killing this group never stops its services.
use crate::{
    agent_backend::{self, BackendSpecification},
    identity::IdentityRegistry,
    launcher::{self, Quota, Specification},
    peers::Peer,
};
use ditto_protocol::agent::{AgentRuntimeStatus, RuntimePhase};
use std::{
    collections::HashMap,
    os::fd::{AsRawFd, FromRawFd, OwnedFd},
    process::Child,
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};

struct State {
    phase: RuntimePhase,
    generation: u64,
    child: Option<Child>,
    peer: Option<Arc<Peer>>,
    backend_pid: Option<u32>,
    backend_handle: Option<OwnedFd>,
    /// `ditto-confine` for the current generation's backend, started by Core.
    backend_supervisor: Option<Child>,
    backend_root: Option<std::path::PathBuf>,
    active: HashMap<String, Instant>,
    last_activity: Instant,
    drain_started: Option<Instant>,
    isolation_verified: bool,
    failure: Option<String>,
}
pub struct AgentManager {
    state: Mutex<State>,
    specification: Option<Specification>,
    backend: Option<BackendSpecification>,
    /// Release after this long without activity (RUN-03: five minutes).
    idle: Duration,
    registry: Arc<IdentityRegistry>,
    socket: std::path::PathBuf,
    state_root: std::path::PathBuf,
}
/// RUN-03: an Agent with nothing to do leaves after five minutes.
pub const IDLE: Duration = Duration::from_secs(300);

impl AgentManager {
    /// Test fixtures only (Core's `--agent-idle-test-seconds` needs the
    /// fixture compositor): a shorter idle limit for the activity logic.
    /// The exit criterion is measured with the real five minutes.
    pub fn with_idle(mut self, idle: Duration) -> Self {
        self.idle = idle;
        self
    }

    pub fn new(
        specification: Option<Specification>,
        backend: Option<BackendSpecification>,
        registry: Arc<IdentityRegistry>,
        socket: std::path::PathBuf,
        state_root: std::path::PathBuf,
    ) -> Self {
        Self {
            state: Mutex::new(State {
                phase: RuntimePhase::Stopped,
                generation: 0,
                child: None,
                peer: None,
                backend_pid: None,
                backend_handle: None,
                backend_supervisor: None,
                backend_root: None,
                active: HashMap::new(),
                last_activity: Instant::now(),
                drain_started: None,
                isolation_verified: false,
                failure: None,
            }),
            specification,
            backend,
            idle: IDLE,
            registry,
            socket,
            state_root,
        }
    }
    fn snapshot(s: &State, installed: bool) -> AgentRuntimeStatus {
        AgentRuntimeStatus {
            installed,
            phase: s.phase,
            generation: s.generation,
            controller_pid: s.child.as_ref().map(Child::id),
            backend_pid: s.backend_pid,
            active_turns: s.active.keys().filter(|k| k.starts_with("turn:")).count() as u32,
            isolation_verified: s.isolation_verified,
            failure_reason: s.failure.clone(),
        }
    }
    pub fn status(&self) -> AgentRuntimeStatus {
        Self::snapshot(
            &self.state.lock().expect("agent manager"),
            self.specification.is_some(),
        )
    }
    pub fn installed(&self) -> bool {
        self.specification.is_some()
    }
    pub fn ensure(&self) -> Result<AgentRuntimeStatus, std::io::Error> {
        let mut s = self.state.lock().expect("agent manager");
        if matches!(
            s.phase,
            RuntimePhase::Starting | RuntimePhase::Ready | RuntimePhase::Draining
        ) {
            if s.phase == RuntimePhase::Ready {
                s.last_activity = Instant::now();
            }
            return Ok(Self::snapshot(&s, self.specification.is_some()));
        }
        let spec = self.specification.as_ref().ok_or_else(|| {
            std::io::Error::new(
                std::io::ErrorKind::NotFound,
                "Agent executable is not installed",
            )
        })?;
        s.generation += 1;
        s.phase = RuntimePhase::Starting;
        s.failure = None;
        s.last_activity = Instant::now();
        // The controller and its backend inherit one aggregate scope. D-06b's
        // service hard limit is not the 150MiB warm PSS acceptance target.
        let quota = Quota::service();
        let mut environment = vec![(
            "DITTO_AGENT_STATE".into(),
            self.state_root.to_string_lossy().to_string(),
        )];
        // The backend starts first and only from Core: its binary, arguments
        // and OS boundary are Core's, and the controller just gets a channel.
        // No hard memory limit is applied to it yet: D-44 sets one from
        // measurements, and D-06b's service quota is not reused for it.
        let mut channel = None;
        if let Some(backend) = &self.backend {
            match agent_backend::launch(backend, &self.state_root, None) {
                Ok(launched) => {
                    environment.push(("DITTO_BACKEND_FD".into(), launcher::CHANNEL_FD.to_string()));
                    environment.push((
                        "DITTO_BACKEND_PROVIDER".into(),
                        if backend.test_provider.is_some() {
                            "ditto_test"
                        } else {
                            "openai"
                        }
                        .into(),
                    ));
                    environment.push((
                        "DITTO_BACKEND_AUTH".into(),
                        if backend.test_provider.is_some() {
                            "test-provider"
                        } else {
                            "chatgpt"
                        }
                        .into(),
                    ));
                    s.backend_pid = Some(launched.program_pid);
                    s.backend_handle = pid_handle(launched.program_pid).ok();
                    s.backend_supervisor = Some(launched.supervisor);
                    s.backend_root = Some(launched.root);
                    channel = Some(launched.channel);
                }
                Err(refusal) => {
                    crate::log::event("agent.backend_refused", &[("reason", refusal.as_str())]);
                    s.failure = Some(refusal.as_str().into());
                }
            }
        }
        match launcher::launch_with_channel(
            &self.registry,
            spec,
            &self.socket,
            Some(&quota),
            &environment,
            channel.as_ref(),
        ) {
            Ok(child) => {
                s.child = Some(child);
                // The startup deadline is the controller's: checking and
                // starting the backend (hashing a large binary on a slow
                // machine) does not eat into it.
                s.last_activity = Instant::now();
            }
            Err(e) => {
                Self::stop_backend(&mut s);
                s.phase = RuntimePhase::Failed;
                s.failure = Some("launch_failed".into());
                return Err(e);
            }
        }
        Ok(Self::snapshot(&s, self.specification.is_some()))
    }
    pub fn attach(&self, peer: Arc<Peer>) -> bool {
        let mut s = self.state.lock().expect("agent manager");
        if s.child.as_ref().map(Child::id) != Some(peer.pid)
            || s.peer.as_ref().is_some_and(|p| !p.is_closed())
        {
            return false;
        }
        s.peer = Some(peer);
        true
    }
    pub fn is_connection(&self, id: &str) -> bool {
        self.state
            .lock()
            .expect("agent manager")
            .peer
            .as_ref()
            .is_some_and(|p| p.connection_id == id && !p.is_closed())
    }
    pub fn peer(&self) -> Option<Arc<Peer>> {
        self.state
            .lock()
            .expect("agent manager")
            .peer
            .as_ref()
            .filter(|p| !p.is_closed())
            .cloned()
    }
    pub fn ready(&self, connection: &str) -> Result<AgentRuntimeStatus, &'static str> {
        let mut s = self.state.lock().expect("agent manager");
        if !s
            .peer
            .as_ref()
            .is_some_and(|p| p.connection_id == connection)
        {
            return Err("Agent generation is not current");
        }
        if s.child.is_none() {
            return Err("Agent is not running");
        }
        // Only Core's own launch of the confined backend counts as evidence;
        // nothing the controller reports about the backend is consulted.
        s.isolation_verified = s
            .backend_supervisor
            .as_mut()
            .is_some_and(|c| matches!(c.try_wait(), Ok(None)));
        s.phase = RuntimePhase::Ready;
        s.last_activity = Instant::now();
        Ok(Self::snapshot(&s, self.specification.is_some()))
    }
    pub fn activity(&self, key: &str, active: bool) {
        let mut s = self.state.lock().expect("agent manager");
        if active {
            s.active.insert(key.into(), Instant::now());
        } else {
            s.active.remove(key);
        }
        s.last_activity = Instant::now();
    }
    pub fn notify(&self, method: &str, params: serde_json::Value) -> bool {
        self.peer().is_some_and(|p| p.notify(method, params))
    }
    pub fn stop(&self) -> AgentRuntimeStatus {
        let mut s = self.state.lock().expect("agent manager");
        if s.child.is_some() && s.phase != RuntimePhase::Draining {
            if let Some(p) = &s.peer {
                p.notify("agent.controller.stop", serde_json::json!({}));
            }
            s.phase = RuntimePhase::Draining;
            s.drain_started = Some(Instant::now());
        }
        Self::snapshot(&s, self.specification.is_some())
    }
    /// Returns the lost connection, so Core fences writers and marks unfinished
    /// tasks unknown without replaying anything. No new request means no restart.
    pub fn tick(&self) -> Option<String> {
        let mut s = self.state.lock().expect("agent manager");
        s.active.retain(|key, at| {
            !key.starts_with("login:") || at.elapsed() < Duration::from_secs(300)
        });
        let exited = s
            .child
            .as_mut()
            .is_some_and(|c| matches!(c.try_wait(), Ok(Some(_))));
        if exited {
            Self::stop_backend(&mut s);
            let connection = s.peer.take().map(|p| {
                p.close();
                p.connection_id.clone()
            });
            s.child = None;
            s.phase = RuntimePhase::Stopped;
            s.active.clear();
            s.isolation_verified = false;
            s.drain_started = None;
            return connection;
        }
        // A backend that dies leaves this generation without a model and
        // without isolation evidence: drain it; the next request relaunches
        // both together. Nothing is replayed.
        let backend_gone = s
            .backend_supervisor
            .as_mut()
            .is_some_and(|c| !matches!(c.try_wait(), Ok(None)));
        if backend_gone {
            s.isolation_verified = false;
            s.failure = Some("backend_exited".into());
            Self::stop_backend(&mut s);
            if matches!(s.phase, RuntimePhase::Ready | RuntimePhase::Starting) {
                if let Some(p) = &s.peer {
                    p.notify("agent.controller.stop", serde_json::json!({}));
                }
                s.phase = RuntimePhase::Draining;
                s.drain_started = Some(Instant::now());
            }
        }
        if s.phase == RuntimePhase::Starting && s.last_activity.elapsed() > Duration::from_secs(10)
        {
            s.failure = Some("startup_timeout".into());
            s.phase = RuntimePhase::Draining;
            s.drain_started = Some(Instant::now() - Duration::from_secs(10));
        }
        if s.phase == RuntimePhase::Ready
            && s.active.is_empty()
            && s.last_activity.elapsed() >= self.idle
        {
            if let Some(p) = &s.peer {
                p.notify("agent.controller.stop", serde_json::json!({}));
            }
            s.phase = RuntimePhase::Draining;
            s.drain_started = Some(Instant::now());
        }
        if s.phase == RuntimePhase::Draining
            && s.drain_started
                .is_some_and(|at| at.elapsed() >= Duration::from_secs(10))
        {
            Self::stop_backend(&mut s);
            if let Some(c) = &mut s.child {
                let _ = c.kill();
            }
            s.failure = Some("drain_timeout".into());
        }
        None
    }
}
impl AgentManager {
    /// Stop the confined backend group. The supervisor kills the program's
    /// process group on exit; the program's own pidfd covers a supervisor
    /// that is already gone.
    fn stop_backend(s: &mut State) {
        if let Some(mut supervisor) = s.backend_supervisor.take() {
            // SAFETY: signalling our own child by its PID while not yet reaped.
            unsafe { libc::kill(supervisor.id() as i32, libc::SIGTERM) };
            let deadline = Instant::now() + Duration::from_secs(3);
            while Instant::now() < deadline && matches!(supervisor.try_wait(), Ok(None)) {
                std::thread::sleep(Duration::from_millis(20));
            }
            let _ = supervisor.kill();
            let _ = supervisor.wait();
        }
        if let Some(handle) = s.backend_handle.take() {
            terminate(&handle);
        }
        if let Some(root) = s.backend_root.take() {
            // Logs and thread state of an ephemeral backend are not a second
            // conversation store: nothing of them outlives the generation.
            agent_backend::clear(&root);
        }
        s.backend_pid = None;
        s.isolation_verified = false;
    }
}

fn pid_handle(pid: u32) -> std::io::Result<OwnedFd> {
    let fd = unsafe { libc::syscall(libc::SYS_pidfd_open, pid, 0) } as i32;
    if fd < 0 {
        return Err(std::io::Error::last_os_error());
    }
    Ok(unsafe { OwnedFd::from_raw_fd(fd) })
}
fn terminate(handle: &OwnedFd) {
    // Retain the handle captured while the descendant is alive. Looking it up
    // by numeric PID after its parent exits could target a reused PID.
    unsafe {
        libc::syscall(
            libc::SYS_pidfd_send_signal,
            handle.as_raw_fd(),
            libc::SIGKILL,
            std::ptr::null::<libc::siginfo_t>(),
            0,
        );
    }
}
