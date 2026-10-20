//! The Shell as a participant and as a supervised client. Core starts it
//! through the controlled launcher and restarts it with backoff; three exits
//! in ten minutes start the rescue UI instead (plan/03/05 §3). What is mounted
//! comes from the Shell's own reports, the observed state `panels.list`
//! answers from and UI swaps are read back against.

use std::{
    collections::VecDeque,
    process::Child,
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};

use ditto_protocol::participant::{ParticipantRole, ShellObservation};

use crate::{
    identity::IdentityRegistry,
    launcher::{self, Specification},
    participants::RemoteParticipant,
    peers::Peer,
};

pub const SHELL_RESTART_BACKOFF: [u64; 3] = [1, 2, 4];
pub const SHELL_FAILURE_WINDOW: Duration = Duration::from_secs(600);
pub const SHELL_FAILURE_LIMIT: usize = 3;

#[derive(Clone, Debug, PartialEq, Eq)]
enum Run {
    NotLaunched,
    Running,
    Backoff { until: Instant },
    RescueUi,
}

struct Inner {
    peer: Option<Arc<Peer>>,
    observation: Option<ShellObservation>,
    reported_at: Option<String>,
    child: Option<Child>,
    rescue_child: Option<Child>,
    exits: VecDeque<Instant>,
    run: Run,
}

pub struct ShellManager {
    inner: Mutex<Inner>,
    spec: Option<Specification>,
    rescue_spec: Option<Specification>,
    registry: Arc<IdentityRegistry>,
    socket: std::path::PathBuf,
}

impl ShellManager {
    pub fn new(
        spec: Option<Specification>,
        rescue_spec: Option<Specification>,
        registry: Arc<IdentityRegistry>,
        socket: std::path::PathBuf,
    ) -> Self {
        Self {
            inner: Mutex::new(Inner {
                peer: None,
                observation: None,
                reported_at: None,
                child: None,
                rescue_child: None,
                exits: VecDeque::new(),
                run: Run::NotLaunched,
            }),
            spec,
            rescue_spec,
            registry,
            socket,
        }
    }

    pub fn launch(&self) {
        let Some(spec) = &self.spec else { return };
        let mut inner = self.inner.lock().expect("shell state");
        match launcher::launch_parsed(&self.registry, spec, &self.socket, None, &[]) {
            Ok(child) => {
                write_pid(child.id());
                inner.child = Some(child);
                inner.run = Run::Running;
            }
            Err(error) => {
                crate::log::event(
                    "shell.start_failed",
                    &[
                        ("reason", &error.to_string()),
                        ("reason_code", crate::log::io_error_code(error.kind())),
                    ],
                );
                inner.run = Run::Backoff {
                    until: Instant::now() + Duration::from_secs(SHELL_RESTART_BACKOFF[0]),
                };
            }
        }
    }

    pub fn attach(&self, peer: Arc<Peer>) {
        let mut inner = self.inner.lock().expect("shell state");
        if let Some(old) = inner.peer.replace(peer) {
            old.close();
        }
        inner.observation = None;
    }

    /// Returns true when it was the current Shell connection.
    pub fn detach(&self, connection_id: &str) -> bool {
        let mut inner = self.inner.lock().expect("shell state");
        if inner
            .peer
            .as_ref()
            .is_some_and(|peer| peer.connection_id == connection_id)
        {
            if let Some(peer) = inner.peer.take() {
                peer.close();
            }
            inner.observation = None;
            return true;
        }
        false
    }

    pub fn peer(&self) -> Option<Arc<Peer>> {
        self.inner
            .lock()
            .expect("shell state")
            .peer
            .clone()
            .filter(|peer| !peer.is_closed())
    }

    pub fn participant(&self) -> Option<RemoteParticipant> {
        self.peer()
            .map(|peer| RemoteParticipant::new(ParticipantRole::Shell, peer))
    }

    pub fn is_connected(&self) -> bool {
        self.peer().is_some()
    }

    pub fn report(&self, observation: ShellObservation) {
        let mut inner = self.inner.lock().expect("shell state");
        inner.observation = Some(observation);
        inner.reported_at = Some(ditto_store::time::now());
    }

    /// A connected Shell that said it answers approval requests.
    pub fn approval_responder(&self) -> bool {
        self.is_connected()
            && self
                .inner
                .lock()
                .expect("shell state")
                .observation
                .as_ref()
                .is_some_and(|o| o.approval_responder)
    }

    pub fn observation(&self) -> (Option<ShellObservation>, Option<String>) {
        let inner = self.inner.lock().expect("shell state");
        (inner.observation.clone(), inner.reported_at.clone())
    }

    /// Wait until a Shell is connected, at most `timeout`.
    pub fn wait_connected(&self, timeout: Duration) -> bool {
        let deadline = Instant::now() + timeout;
        while Instant::now() < deadline {
            if self.is_connected() {
                return true;
            }
            std::thread::sleep(Duration::from_millis(20));
        }
        self.is_connected()
    }

    /// Supervision step. Returns true when the Shell exited since last tick
    /// (instability for the last-known-good observation period).
    pub fn tick(&self) -> bool {
        let mut exited = false;
        let mut relaunch = false;
        let mut rescue = false;
        {
            let mut inner = self.inner.lock().expect("shell state");
            let now = Instant::now();
            if let Some(child) = inner.child.as_mut() {
                if let Ok(Some(status)) = child.try_wait() {
                    crate::log::process_exit("shell.exited", status);
                    inner.child = None;
                    exited = true;
                    inner.exits.push_back(now);
                    while inner
                        .exits
                        .front()
                        .is_some_and(|at| now.duration_since(*at) > SHELL_FAILURE_WINDOW)
                    {
                        inner.exits.pop_front();
                    }
                    if supervisor_requested_rescue() {
                        // The supervisor killed a hung Shell: restarting it
                        // would hang on the same provider again. Core starts
                        // the rescue UI, which (unlike the supervisor's unit)
                        // is connected to Core.
                        inner.run = Run::RescueUi;
                        rescue = true;
                    } else if inner.exits.len() >= SHELL_FAILURE_LIMIT {
                        inner.run = Run::RescueUi;
                        rescue = true;
                    } else {
                        let step = SHELL_RESTART_BACKOFF
                            [(inner.exits.len() - 1).min(SHELL_RESTART_BACKOFF.len() - 1)];
                        inner.run = Run::Backoff {
                            until: now + Duration::from_secs(step),
                        };
                    }
                }
            }
            if let Run::Backoff { until } = inner.run {
                if until <= now && self.spec.is_some() {
                    relaunch = true;
                }
            }
        }
        if relaunch {
            self.launch();
        }
        if rescue {
            self.start_rescue_ui();
        }
        exited
    }

    pub fn start_rescue_ui(&self) {
        let Some(spec) = &self.rescue_spec else {
            crate::log::event("shell.rescue_ui_missing", &[]);
            return;
        };
        let mut inner = self.inner.lock().expect("shell state");
        if inner
            .rescue_child
            .as_mut()
            .is_some_and(|child| child.try_wait().ok().flatten().is_none())
        {
            return;
        }
        match launcher::launch_parsed(&self.registry, spec, &self.socket, None, &[]) {
            Ok(child) => inner.rescue_child = Some(child),
            Err(error) => crate::log::event(
                "shell.rescue_ui_failed",
                &[
                    ("reason", &error.to_string()),
                    ("reason_code", crate::log::io_error_code(error.kind())),
                ],
            ),
        }
    }

    /// Leave the rescue UI for the normal Shell: the exit count starts over,
    /// the supervisor's rescue request is cleared (or Core would treat the
    /// next exit as another hang), the rescue UI stops and the Shell is
    /// launched. Returns whether the rescue UI was showing.
    pub fn resume(&self) -> bool {
        let was_rescue = {
            let mut inner = self.inner.lock().expect("shell state");
            let was_rescue = inner.run == Run::RescueUi;
            inner.exits.clear();
            if let Some(mut child) = inner.rescue_child.take() {
                let _ = child.kill();
                let _ = child.wait();
            }
            if inner
                .child
                .as_mut()
                .is_some_and(|child| child.try_wait().ok().flatten().is_none())
            {
                // A Shell is already running: nothing to start.
                inner.run = Run::Running;
                return was_rescue;
            }
            was_rescue
        };
        if let Some(path) = runtime_dir().map(|dir| dir.join("rescue-request.json")) {
            let _ = std::fs::remove_file(path);
        }
        // The supervisor starts the rescue UI as a unit of its own.
        let _ = std::process::Command::new("systemctl")
            .args(["--user", "stop", "--no-block", "ditto-rescue.service"])
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status();
        crate::log::event(
            "shell.resume",
            &[("from_rescue_ui", if was_rescue { "true" } else { "false" })],
        );
        self.launch();
        was_rescue
    }

    pub fn in_rescue_ui(&self) -> bool {
        self.inner.lock().expect("shell state").run == Run::RescueUi
    }
}

fn runtime_dir() -> Option<std::path::PathBuf> {
    std::env::var_os("DITTO_RUNTIME_DIR")
        .map(std::path::PathBuf::from)
        .or_else(|| {
            std::env::var_os("XDG_RUNTIME_DIR")
                .map(|dir| std::path::PathBuf::from(dir).join("ditto"))
        })
}

/// `ditto-supervisor` finds the Shell by its scope or by this file. The start
/// time (field 22 of `/proc/<pid>/stat`) lets it refuse a reused PID.
fn write_pid(pid: u32) {
    let Some(directory) = runtime_dir() else {
        return;
    };
    let start = std::fs::read_to_string(format!("/proc/{pid}/stat"))
        .ok()
        .and_then(|stat| {
            stat.rsplit_once(')')
                .and_then(|(_, rest)| rest.split_whitespace().nth(19).map(String::from))
        })
        .unwrap_or_default();
    let _ = std::fs::write(directory.join("shell.pid"), format!("{pid} {start}\n"));
}

/// The supervisor killed an unresponsive Shell and asked for the rescue UI:
/// restarting the Shell would hang on the same provider again.
fn supervisor_requested_rescue() -> bool {
    let Some(path) = runtime_dir().map(|dir| dir.join("rescue-request.json")) else {
        return false;
    };
    let fresh = std::fs::metadata(&path)
        .and_then(|meta| meta.modified())
        .ok()
        .and_then(|modified| modified.elapsed().ok())
        .is_some_and(|age| age < Duration::from_secs(30));
    fresh
        && std::fs::read_to_string(&path)
            .ok()
            .and_then(|text| serde_json::from_str::<serde_json::Value>(&text).ok())
            .is_some_and(|request| request["reason"] == "shell_unresponsive")
}

#[cfg(test)]
mod crash_tests {
    use super::*;

    #[test]
    fn reaped_signal_exits_count_towards_backoff_and_rescue() {
        let manager = ShellManager::new(
            None,
            None,
            Arc::new(IdentityRegistry::new()),
            "core.sock".into(),
        );
        for failure in 1..=SHELL_FAILURE_LIMIT {
            let mut child = std::process::Command::new("/bin/sleep")
                .arg("30")
                .spawn()
                .unwrap();
            child.kill().unwrap();
            let status = child.wait().unwrap();
            use std::os::unix::process::ExitStatusExt;
            assert_eq!(status.signal(), Some(libc::SIGKILL));
            manager.inner.lock().unwrap().child = Some(child);
            let before = Instant::now();
            assert!(manager.tick());
            let inner = manager.inner.lock().unwrap();
            assert_eq!(inner.exits.len(), failure);
            if failure < SHELL_FAILURE_LIMIT {
                let Run::Backoff { until } = inner.run else {
                    panic!("no backoff")
                };
                assert!(until >= before + Duration::from_secs(SHELL_RESTART_BACKOFF[failure - 1]));
            } else {
                assert_eq!(inner.run, Run::RescueUi);
            }
        }
    }

    #[test]
    fn signal_exits_back_off_issue_fresh_tokens_and_reach_rescue() {
        let directory =
            std::env::temp_dir().join(format!("shell-crash-{}", ditto_protocol::ids::ulid()));
        std::fs::create_dir_all(&directory).unwrap();
        let specification = |kind: &str| Specification {
            kind: kind.into(),
            version: "0.3.1".into(),
            executable: "/bin/sh".into(),
            arguments: vec![
                "-c".into(),
                "read -r token <&3; printf '%s' \"$token\" > \"$1\"; kill -STOP $$".into(),
                "fixture".into(),
                directory.join(kind).into_os_string(),
            ],
        };
        let registry = Arc::new(IdentityRegistry::new());
        let manager = ShellManager::new(
            Some(specification("quickshell")),
            Some(specification("rescue-shell")),
            Arc::clone(&registry),
            directory.join("core.sock"),
        );
        manager.launch();
        assert!(
            manager.inner.lock().unwrap().child.is_some(),
            "controlled launch failed; see shell.start_failed"
        );
        let mut previous_token = String::new();
        for failure in 1..=SHELL_FAILURE_LIMIT {
            let path = directory.join("quickshell");
            let deadline = Instant::now() + Duration::from_secs(3);
            while !std::fs::read_to_string(&path).is_ok_and(|text| !text.is_empty())
                && Instant::now() < deadline
            {
                std::thread::sleep(Duration::from_millis(10));
            }
            let token = std::fs::read_to_string(&path).unwrap();
            std::fs::remove_file(path).unwrap();
            assert_ne!(token, previous_token);
            let pid = manager.inner.lock().unwrap().child.as_ref().unwrap().id();
            // SAFETY: getuid has no preconditions; the PID is our stopped child.
            let uid = unsafe { libc::getuid() };
            registry
                .verify_once(&token, uid, pid, "quickshell", "0.3.1")
                .unwrap();
            assert!(registry
                .verify_once(&token, uid, pid, "quickshell", "0.3.1")
                .is_err());
            previous_token = token;
            {
                let mut inner = manager.inner.lock().unwrap();
                let child = inner.child.as_mut().unwrap();
                child.kill().unwrap();
                child.wait().unwrap();
            }
            assert!(manager.tick());
            assert_eq!(manager.inner.lock().unwrap().exits.len(), failure);
            if failure < SHELL_FAILURE_LIMIT {
                let mut inner = manager.inner.lock().unwrap();
                let Run::Backoff { until } = inner.run else {
                    panic!("no backoff");
                };
                assert!(until > Instant::now());
                assert!(inner.child.is_none());
                drop(inner);
                assert!(!manager.tick());
                inner = manager.inner.lock().unwrap();
                assert!(inner.child.is_none());
                inner.run = Run::Backoff {
                    until: Instant::now(),
                };
                drop(inner);
                manager.tick();
            }
        }
        assert!(manager.in_rescue_ui());
        let mut rescue = manager.inner.lock().unwrap().rescue_child.take().unwrap();
        rescue.kill().unwrap();
        rescue.wait().unwrap();
        std::fs::remove_dir_all(directory).unwrap();
    }
}
