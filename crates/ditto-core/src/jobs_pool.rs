//! Core's pool for trusted background jobs (G2-CORE-05, AGENT-11). At most
//! two run at a time across the whole product; the rest wait in the Store's
//! queue. Each runs as `ditto-worker <kind>` in its own systemd user scope
//! with D-06b's short-tool quota, so a runaway job is stopped by the kernel,
//! not by trust. Without a systemd user manager to enforce that, the pool is
//! unavailable rather than unlimited.
use crate::core::Core;
use ditto_protocol::{
    services::{Job, JobState},
    DesktopEventPayload,
};
use std::{
    collections::HashMap,
    io::{BufRead, BufReader, Write},
    path::PathBuf,
    process::{Child, Command, Stdio},
    sync::{
        mpsc::{self, Receiver, Sender},
        Arc, Mutex, Weak,
    },
    time::{Duration, Instant},
};

/// Global limit on heavy work (plan/04/06 §3).
pub const MAX_RUNNING: i64 = 2;
/// After TERM, a worker has this long before KILL.
const TERM_GRACE: Duration = Duration::from_secs(3);

pub struct KindSpec {
    pub deadline_ms: u64,
    pub memory_max: &'static str,
    pub cpu_quota: &'static str,
    pub tasks_max: u32,
    pub test_only: bool,
}

/// The trusted kinds. The short-tool class of D-06b for all of them.
pub fn kind_spec(kind: &str) -> Option<KindSpec> {
    let short = |deadline_ms, test_only| KindSpec {
        deadline_ms,
        memory_max: "256M",
        cpu_quota: "50%",
        tasks_max: 32,
        test_only,
    };
    match kind {
        "packages.verify" => Some(short(120_000, false)),
        "generation.validate" | "generation.preview" => Some(KindSpec {
            deadline_ms: 60000,
            memory_max: "512M",
            cpu_quota: "100%",
            tasks_max: 64,
            test_only: false,
        }),
        "test.spin" | "test.memory" | "test.sleep" => Some(short(120_000, true)),
        _ => None,
    }
}

struct Running {
    child: Child,
    unit: String,
    started: Instant,
    deadline: Duration,
    term_sent: Option<Instant>,
    deadline_hit: bool,
    lines: Receiver<String>,
    result: Option<serde_json::Value>,
    error: Option<String>,
}

pub struct JobPool {
    worker: Option<PathBuf>,
    pub available: bool,
    pub recovery_clean: std::sync::atomic::AtomicBool,
    pub test_kinds: bool,
    running: Mutex<HashMap<String, Running>>,
    wake: Mutex<Option<Sender<()>>>,
}

fn manager_command(binary: &str) -> Command {
    let mut command = Command::new(binary);
    command.env(
        "DBUS_SESSION_BUS_ADDRESS",
        format!("unix:path=/run/user/{}/bus", unsafe { libc::getuid() }),
    );
    command
}

fn systemd_user_available() -> bool {
    manager_command("/usr/bin/systemctl")
        .args(["--user", "is-system-running"])
        .env_remove("NOTIFY_SOCKET")
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .output()
        .map(|o| {
            let state = String::from_utf8_lossy(&o.stdout);
            // "degraded" still runs units; only an unreachable manager fails.
            ["running", "degraded", "starting"].contains(&state.trim())
        })
        .unwrap_or(false)
}

impl JobPool {
    pub fn new(test_kinds: bool) -> Self {
        let worker = std::env::current_exe()
            .ok()
            .and_then(|exe| exe.parent().map(|dir| dir.join("ditto-worker")))
            .filter(|path| path.is_file());
        let available = worker.is_some() && systemd_user_available();
        Self {
            worker,
            available,
            recovery_clean: std::sync::atomic::AtomicBool::new(false),
            test_kinds,
            running: Mutex::new(HashMap::new()),
            wake: Mutex::new(None),
        }
    }

    pub fn ready(&self) -> bool {
        self.available
            && self
                .recovery_clean
                .load(std::sync::atomic::Ordering::SeqCst)
    }

    /// Whether a kind may be submitted here.
    pub fn accepts(&self, kind: &str) -> bool {
        kind_spec(kind).is_some_and(|spec| !spec.test_only || self.test_kinds)
    }

    pub fn wake(&self) {
        if let Some(sender) = self.wake.lock().expect("pool wake").as_ref() {
            let _ = sender.send(());
        }
    }

    pub fn running_units(&self) -> Vec<(String, u32, String)> {
        self.running
            .lock()
            .expect("pool")
            .iter()
            .map(|(id, r)| (id.clone(), r.child.id(), r.unit.clone()))
            .collect()
    }
}

/// Start the scheduler thread for as long as Core lives.
pub fn install(core: &Arc<Core>) {
    if !core.jobs.available {
        crate::log::event("jobs.pool_unavailable", &[]);
        return;
    }
    let (sender, receiver) = mpsc::channel();
    *core.jobs.wake.lock().expect("pool wake") = Some(sender);
    let weak: Weak<Core> = Arc::downgrade(core);
    let _ = std::thread::Builder::new()
        .name("ditto-jobs".into())
        .spawn(move || loop {
            let _ = receiver.recv_timeout(Duration::from_millis(200));
            let Some(core) = weak.upgrade() else { return };
            step(&core);
        });
}

fn publish(core: &Core, job: Job) {
    core.publish(DesktopEventPayload::JobsUpdated { job });
}

fn write<T: Send + 'static>(
    core: &Core,
    work: impl FnOnce(&rusqlite::Connection) -> ditto_store::StoreResult<T> + Send + 'static,
) -> Option<T> {
    core.coordinate(Duration::from_secs(5), move |c| {
        c.store().write(|tx| work(tx))
    })
    .ok()
    .and_then(Result::ok)
}

/// The packages a verify job checks, decided when it starts.
fn verify_params(core: &Core) -> serde_json::Value {
    let packages = core
        .read(|c| {
            let mut statement = c.prepare("SELECT package_id, version, sha256, tree_sha256 FROM plugin_packages ORDER BY package_id, version")?;
            let rows = statement
                .query_map([], |r| {
                    Ok((
                        r.get::<_, String>(0)?,
                        r.get::<_, String>(1)?,
                        r.get::<_, String>(2)?,
                        r.get::<_, String>(3)?,
                    ))
                })?
                .collect::<Result<Vec<_>, _>>()?;
            Ok(rows)
        })
        .unwrap_or_default();
    serde_json::json!({"packages": packages.into_iter().map(|(id, version, sha, tree)| serde_json::json!({
        "package_id": id, "version": version, "tree_sha256": tree,
        "dir": core.paths.package_dir(&sha),
    })).collect::<Vec<_>>()})
}

fn spawn(
    core: &Core,
    job: &Job,
    params: serde_json::Value,
    deadline_ms: u64,
) -> Result<Running, String> {
    let spec = kind_spec(&job.kind).ok_or("job.unknown_kind".to_string())?;
    let worker = core
        .jobs
        .worker
        .clone()
        .ok_or("job.pool_unavailable".to_string())?;
    let unit = format!(
        "ditto-job-{}",
        job.job_id
            .to_ascii_lowercase()
            .replace(|c: char| !c.is_ascii_alphanumeric() && c != '-', "-")
    );
    let params = if job.kind == "packages.verify" {
        verify_params(core)
    } else {
        params
    };
    let mut child = manager_command("/usr/bin/systemd-run")
        .args(["--user", "--scope", "--quiet", "--collect"])
        .arg(format!("--unit={unit}"))
        .args(["-p", &format!("MemoryMax={}", spec.memory_max)])
        .args(["-p", "MemorySwapMax=0"])
        .args(["-p", &format!("CPUQuota={}", spec.cpu_quota)])
        .args(["-p", &format!("TasksMax={}", spec.tasks_max)])
        .arg("--")
        .arg(&worker)
        .arg(&job.kind)
        .env_clear()
        .envs(
            [
                "XDG_RUNTIME_DIR",
                "DBUS_SESSION_BUS_ADDRESS",
                "PATH",
                "LANG",
                "HOME",
                "WAYLAND_DISPLAY",
            ]
            .iter()
            .filter_map(|k| std::env::var_os(k).map(|v| (*k, v))),
        )
        .env(
            "DBUS_SESSION_BUS_ADDRESS",
            format!("unix:path=/run/user/{}/bus", unsafe { libc::getuid() }),
        )
        .env(
            "DITTO_JOB_CORE_WITNESS",
            format!(
                "{}:{}",
                std::process::id(),
                process_start(std::process::id()).ok_or("job.core_identity_unavailable")?
            ),
        )
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|_| "job.spawn_failed".to_string())?;
    if let Some(mut stdin) = child.stdin.take() {
        let _ = stdin.write_all(params.to_string().as_bytes());
    }
    let stdout = child.stdout.take().ok_or("job.spawn_failed".to_string())?;
    let (lines_tx, lines) = mpsc::channel();
    std::thread::spawn(move || {
        let mut total = 0usize;
        for line in BufReader::new(stdout).lines().map_while(Result::ok) {
            total += line.len();
            // A worker that floods its output stops being heard.
            if total > 256 * 1024 || lines_tx.send(line).is_err() {
                break;
            }
        }
    });
    Ok(Running {
        child,
        unit,
        started: Instant::now(),
        deadline: Duration::from_millis(deadline_ms.min(spec.deadline_ms)),
        term_sent: None,
        deadline_hit: false,
        lines,
        result: None,
        error: None,
    })
}

/// Whether the scope's cgroup recorded an OOM kill.
fn oom_killed(unit: &str) -> bool {
    manager_command("/usr/bin/systemctl")
        .args([
            "--user",
            "show",
            "-p",
            "Result",
            "--value",
            &format!("{unit}.scope"),
        ])
        .env_remove("NOTIFY_SOCKET")
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim() == "oom-kill")
        .unwrap_or(false)
}

fn signal_group(running: &Running, signal: i32) {
    // The worker is the scope's main process; it runs no children of its
    // own, but stopping the scope also takes any it might have left.
    // SAFETY: signalling our own child process by PID while not yet reaped.
    unsafe { libc::kill(running.child.id() as i32, signal) };
    if signal == libc::SIGKILL {
        let _ = manager_command("/usr/bin/systemctl")
            .args([
                "--user",
                "kill",
                "--signal=KILL",
                &format!("{}.scope", running.unit),
            ])
            .env_remove("NOTIFY_SOCKET")
            .stderr(Stdio::null())
            .status();
    }
}

fn step(core: &Arc<Core>) {
    if core.is_recovering() || !core.jobs.ready() {
        return;
    }
    // 1. Running workers: progress, deadlines, cancels, exits.
    let ids: Vec<String> = core
        .jobs
        .running
        .lock()
        .expect("pool")
        .keys()
        .cloned()
        .collect();
    for id in ids {
        let mut finished: Option<(JobState, Option<serde_json::Value>, Option<String>)> = None;
        let mut phase: Option<(String, Option<f64>)> = None;
        {
            let mut table = core.jobs.running.lock().expect("pool");
            let Some(running) = table.get_mut(&id) else {
                continue;
            };
            while let Ok(line) = running.lines.try_recv() {
                let Ok(value) = serde_json::from_str::<serde_json::Value>(&line) else {
                    continue;
                };
                if let Some(result) = value.get("result") {
                    running.result = Some(result.clone());
                } else if let Some(error) = value.get("error").and_then(|e| e.as_str()) {
                    running.error = Some(error.chars().take(64).collect());
                } else if let Some(text) = value.get("phase").and_then(|p| p.as_str()) {
                    phase = Some((
                        text.chars().take(80).collect(),
                        value
                            .get("progress")
                            .and_then(|p| p.as_f64())
                            .map(|p| p.clamp(0.0, 1.0)),
                    ));
                }
            }
            let cancel = core
                .read(|c| ditto_store::jobs::cancel_requested(c, &id))
                .unwrap_or(false);
            if running.term_sent.is_none()
                && (cancel || running.started.elapsed() > running.deadline)
            {
                running.deadline_hit = !cancel;
                signal_group(running, libc::SIGTERM);
                running.term_sent = Some(Instant::now());
            } else if running
                .term_sent
                .is_some_and(|at| at.elapsed() > TERM_GRACE)
            {
                signal_group(running, libc::SIGKILL);
            }
            if let Ok(Some(status)) = running.child.try_wait() {
                // Drain what the worker wrote before it ended.
                std::thread::sleep(Duration::from_millis(20));
                while let Ok(line) = running.lines.try_recv() {
                    if let Ok(value) = serde_json::from_str::<serde_json::Value>(&line) {
                        if let Some(result) = value.get("result") {
                            running.result = Some(result.clone());
                        } else if let Some(error) = value.get("error").and_then(|e| e.as_str()) {
                            running.error = Some(error.chars().take(64).collect());
                        }
                    }
                }
                finished = Some(if cancel {
                    (JobState::Cancelled, None, Some("job.cancelled".into()))
                } else if running.deadline_hit {
                    (JobState::Failed, None, Some("job.deadline".into()))
                } else if status.success() && running.result.is_some() {
                    (JobState::Succeeded, running.result.clone(), None)
                } else if oom_killed(&running.unit)
                    || std::os::unix::process::ExitStatusExt::signal(&status) == Some(libc::SIGKILL)
                {
                    (JobState::Failed, None, Some("job.out_of_memory".into()))
                } else {
                    (
                        JobState::Failed,
                        None,
                        Some(running.error.clone().unwrap_or_else(|| "job.failed".into())),
                    )
                });
                table.remove(&id);
            }
        }
        if let Some((text, progress)) = phase {
            let job_id = id.clone();
            if write(core, move |c| {
                ditto_store::jobs::set_phase(c, &job_id, &text, progress)?;
                if text == "preview_opened" {
                    let job = ditto_store::jobs::get(c, &job_id)?;
                    crate::generation::preview_event(c, &job, true)?;
                }
                Ok(())
            })
            .is_some()
            {
                if let Ok(job) = core.read(|c| ditto_store::jobs::get(c, &id)) {
                    publish(core, job);
                }
            }
        }
        if let Some((state, result, error)) = finished {
            let job_id = id.clone();
            if let Some(job) = write(core, move |c| {
                let job = ditto_store::jobs::finish(
                    c,
                    &job_id,
                    state,
                    result.as_ref(),
                    error.as_deref(),
                )?;
                crate::generation::finish_job(c, &job)?;
                Ok(job)
            }) {
                crate::log::event(
                    "jobs.finished",
                    &[
                        ("job_id", job.job_id.as_str()),
                        ("kind", job.kind.as_str()),
                        ("error", job.error_key.as_deref().unwrap_or("")),
                    ],
                );
                publish(core, job);
            }
        }
    }
    // 2. Admission: start queued jobs while the global limit allows.
    loop {
        let running = core
            .read(ditto_store::jobs::running_count)
            .unwrap_or(MAX_RUNNING);
        if running >= MAX_RUNNING {
            return;
        }
        let Ok(Some((job, params, deadline))) = core.read(ditto_store::jobs::next_queued) else {
            return;
        };
        if !core.jobs.accepts(&job.kind) {
            let job_id = job.job_id.clone();
            if let Some(job) = write(core, move |c| {
                ditto_store::jobs::finish(
                    c,
                    &job_id,
                    JobState::Failed,
                    None,
                    Some("job.unknown_kind"),
                )
            }) {
                publish(core, job);
            }
            continue;
        }
        match spawn(core, &job, params, deadline) {
            Ok(worker) => {
                let (job_id, unit) = (job.job_id.clone(), worker.unit.clone());
                let started = write(core, move |c| ditto_store::jobs::start(c, &job_id, &unit))
                    .unwrap_or(false);
                if !started {
                    // Cancelled between the read and the start.
                    signal_group(&worker, libc::SIGKILL);
                    continue;
                }
                crate::log::event(
                    "jobs.started",
                    &[
                        ("job_id", job.job_id.as_str()),
                        ("kind", job.kind.as_str()),
                        ("unit", worker.unit.as_str()),
                    ],
                );
                core.jobs
                    .running
                    .lock()
                    .expect("pool")
                    .insert(job.job_id.clone(), worker);
                if let Ok(job) = core.read(|c| ditto_store::jobs::get(c, &job.job_id)) {
                    publish(core, job);
                }
            }
            Err(error) => {
                let job_id = job.job_id.clone();
                if let Some(job) = write(core, move |c| {
                    let job = ditto_store::jobs::finish(
                        c,
                        &job_id,
                        JobState::Failed,
                        None,
                        Some(&error),
                    )?;
                    crate::generation::finish_job(c, &job)?;
                    Ok(job)
                }) {
                    publish(core, job);
                }
            }
        }
    }
}

fn process_start(pid: u32) -> Option<String> {
    std::fs::read_to_string(format!("/proc/{pid}/stat"))
        .ok()?
        .rsplit_once(')')?
        .1
        .split_whitespace()
        .nth(19)
        .map(str::to_owned)
}
/// Stop only persisted Core-owned scopes before admitting replacement work.
pub fn reap_interrupted(c: &rusqlite::Connection) -> ditto_store::StoreResult<()> {
    let mut statement = c.prepare(
        // A previous boot may have marked work interrupted while cleanup was
        // unavailable. Keep checking those scopes on every restart as well.
        "SELECT job_id,unit FROM jobs WHERE unit IS NOT NULL AND
         (state IN ('running','cancelling') OR (state = 'failed' AND error_key = 'job.interrupted')
          OR (state = 'cancelled' AND error_key = 'job.cancelled'))",
    )?;
    let rows = statement
        .query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))?
        .collect::<Result<Vec<_>, _>>()?;
    for (id, unit) in rows {
        let expected = format!(
            "ditto-job-{}",
            id.to_ascii_lowercase()
                .replace(|ch: char| !ch.is_ascii_alphanumeric() && ch != '-', "-")
        );
        if unit != expected {
            return Err(ditto_store::StoreError::Invalid(
                "interrupted worker unit identity mismatch".into(),
            ));
        }
        let scope = format!("{unit}.scope");
        // Remember the kernel path before stop: systemd can retain an inactive
        // transient unit with an empty ControlGroup property until it is GC'd.
        let before = manager_command("/usr/bin/systemctl")
            .args(["--user", "show", &scope, "-p", "ControlGroup", "--value"])
            .output()?;
        let previous_group = String::from_utf8_lossy(&before.stdout).trim().to_owned();
        if !previous_group.is_empty() && !previous_group.ends_with(&format!("/{scope}")) {
            return Err(ditto_store::StoreError::Invalid(
                "interrupted worker cgroup identity mismatch".into(),
            ));
        }
        // Interrupted work cannot finish its transaction. Reap the complete
        // old scope immediately instead of waiting for the manager's default
        // graceful-stop timeout while holding replacement admission closed.
        let _ = manager_command("/usr/bin/systemctl")
            .args(["--user", "kill", "--signal=KILL", "--kill-whom=all", &scope])
            .output()?;
        let result = manager_command("/usr/bin/systemctl")
            .args(["--user", "stop", "--no-block", &scope])
            .output()?;
        // An already-collected unit is also empty; verify through LoadState.
        let mut clean = false;
        let mut last_observed = String::new();
        for _ in 0..100 {
            let out = manager_command("/usr/bin/systemctl")
                .args([
                    "--user",
                    "show",
                    &scope,
                    "-p",
                    "LoadState",
                    "-p",
                    "ActiveState",
                    "-p",
                    "ControlGroup",
                ])
                .output()?;
            let text = String::from_utf8_lossy(&out.stdout);
            let collected = text.lines().any(|l| l == "LoadState=not-found");
            let current_group = text.lines().find_map(|l| l.strip_prefix("ControlGroup="));
            let path = current_group
                .filter(|path| !path.is_empty())
                .or_else(|| (!previous_group.is_empty()).then_some(previous_group.as_str()));
            let empty = path
                .filter(|path| path.ends_with(&format!("/{scope}")))
                .is_some_and(|path| {
                    let events = std::path::Path::new("/sys/fs/cgroup")
                        .join(path.trim_start_matches('/'))
                        .join("cgroup.events");
                    match std::fs::read_to_string(events) {
                        Ok(text) => text.lines().any(|l| l == "populated 0"),
                        Err(e) => e.kind() == std::io::ErrorKind::NotFound,
                    }
                });
            let inactive_without_group = out.status.success()
                && previous_group.is_empty()
                && current_group == Some("")
                && text
                    .lines()
                    .any(|l| l == "ActiveState=inactive" || l == "ActiveState=failed");
            last_observed = text.into_owned();
            if collected || empty || inactive_without_group {
                clean = true;
                break;
            }
            if !result.status.success() && !out.status.success() {
                break;
            }
            std::thread::sleep(Duration::from_millis(20));
        }
        if !clean {
            return Err(ditto_store::StoreError::Invalid(format!(
                "interrupted worker cleanup unconfirmed: {scope}: {last_observed}"
            )));
        }
        // Clear only after proof. If this boot or a later Store write fails,
        // the persisted unit remains a cleanup obligation for the next boot.
        c.execute("UPDATE jobs SET unit = NULL WHERE job_id = ?1", [&id])?;
    }
    Ok(())
}

#[cfg(test)]
mod recovery_tests {
    use super::*;

    #[test]
    fn terminal_interrupted_and_cancelled_jobs_remain_cleanup_obligations() {
        for (state, error) in [
            ("failed", "job.interrupted"),
            ("cancelled", "job.cancelled"),
        ] {
            let c = rusqlite::Connection::open_in_memory().unwrap();
            c.execute_batch("CREATE TABLE jobs(job_id TEXT,unit TEXT,state TEXT,error_key TEXT);")
                .unwrap();
            c.execute(
                "INSERT INTO jobs VALUES ('job-old','unrelated-user-unit',?1,?2)",
                [state, error],
            )
            .unwrap();
            // Refuse the corrupt identity before touching any manager unit,
            // even though the job was already terminal on a previous boot.
            assert!(reap_interrupted(&c)
                .unwrap_err()
                .to_string()
                .contains("unit identity mismatch"));
            let unit: String = c
                .query_row("SELECT unit FROM jobs", [], |r| r.get(0))
                .unwrap();
            assert_eq!(unit, "unrelated-user-unit");
            c.execute("UPDATE jobs SET unit = NULL", []).unwrap();
            reap_interrupted(&c).unwrap();
        }
    }
}
