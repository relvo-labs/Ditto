use ditto_test_host::{
    deny_inet_sockets, landlock_abi, Boundary, Enforcement, ResourceEvidence, DEFAULT_DEADLINE_MS,
    MAX_DEADLINE_MS,
};
use serde::{Deserialize, Serialize};
use std::{
    fs,
    io::{self, Read, Write},
    os::{
        fd::AsRawFd,
        unix::{
            fs::{symlink, DirBuilderExt},
            net::{UnixListener, UnixStream},
            process::CommandExt,
        },
    },
    path::Path,
    process::{Child, Command, Stdio},
    sync::atomic::{AtomicBool, Ordering},
    thread,
    time::{Duration, Instant},
};

const PROBES: &[&str] = &[
    "files", "network", "signals", "spawn", "memory", "busy", "timeout", "spoof", "orphan",
];
static CANCELLED: AtomicBool = AtomicBool::new(false);
extern "C" fn cancel(_: i32) {
    CANCELLED.store(true, Ordering::SeqCst);
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Completion {
    exit_code: Option<i32>,
    output: String,
}

#[derive(Debug, Serialize)]
struct Report {
    format_version: u32,
    probe: String,
    unit: String,
    boundary: Boundary,
    outcome: String,
    service_result: String,
    completion: Option<Completion>,
    cleanup_complete: bool,
    diagnostics: String,
    elapsed_ms: u128,
    // This development tool has no activation path, even for full diagnostics.
    candidate_activation_available: bool,
}

impl Report {
    fn unavailable(probe: &str, error: &str, elapsed_ms: u128) -> Self {
        Self {
            format_version: 1,
            probe: probe.into(),
            unit: String::new(),
            boundary: Boundary::unavailable(error),
            outcome: "unavailable".into(),
            service_result: "not_observed".into(),
            completion: None,
            cleanup_complete: false,
            diagnostics: error.into(),
            elapsed_ms,
            candidate_activation_available: false,
        }
    }
}

fn invalid(message: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidInput, message)
}
fn ctl(args: &[&str]) -> io::Result<std::process::Output> {
    Command::new("/usr/bin/systemctl")
        .args(["--user", "--no-ask-password"])
        .args(args)
        .env_remove("NOTIFY_SOCKET")
        .output()
}

fn process_start(pid: u32) -> Option<String> {
    let text = fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
    // comm may contain spaces and parentheses. Field 22 follows the last ')'.
    text.rsplit_once(')')?
        .1
        .split_whitespace()
        .nth(19)
        .map(str::to_owned)
}

fn bounded_read<R: Read + Send + 'static>(mut input: R) -> thread::JoinHandle<String> {
    thread::spawn(move || {
        let mut saved = Vec::new();
        let mut chunk = [0u8; 4096];
        while let Ok(count) = input.read(&mut chunk) {
            if count == 0 {
                break;
            }
            let take = count.min((64 * 1024usize).saturating_sub(saved.len()));
            saved.extend_from_slice(&chunk[..take]);
        }
        String::from_utf8_lossy(&saved).into_owned()
    })
}

fn emit(value: &impl Serialize) -> io::Result<()> {
    let mut out = io::stdout().lock();
    serde_json::to_writer(&mut out, value)?;
    writeln!(out)?;
    out.flush()
}

fn runner(args: &[String]) -> io::Result<()> {
    if args.len() != 6 {
        return Err(invalid("invalid private runner arguments"));
    }
    let (kind, root, unit) = (&args[0], Path::new(&args[1]), &args[2]);
    let deadline: u64 = args[3].parse().map_err(|_| invalid("deadline"))?;
    let launcher: u32 = args[4].parse().map_err(|_| invalid("launcher"))?;
    let original_start = &args[5];
    if !PROBES.contains(&kind.as_str()) || !(100..=MAX_DEADLINE_MS).contains(&deadline) {
        return Err(invalid("probe policy"));
    }
    let resources = ResourceEvidence::read()?;
    if !resources.cgroup.ends_with(&format!("/{unit}.service")) || !resources.matches_policy() {
        emit(&Boundary::verified(
            resources,
            landlock_abi(),
            false,
            false,
            false,
        ))?;
        return Err(io::Error::other("cgroup policy is not enforced"));
    }
    // Verify the independent service deadline as well as its cgroup limits.
    let timeout = ctl(&[
        "show",
        &format!("{unit}.service"),
        "-p",
        "RuntimeMaxUSec",
        "--value",
    ])?;
    // systemctl formats timespans; compare microseconds via systemd's parser.
    let normalized = Command::new("/usr/bin/systemd-analyze")
        .args(["timespan", String::from_utf8_lossy(&timeout.stdout).trim()])
        .output()?;
    let actual = String::from_utf8_lossy(&normalized.stdout)
        .lines()
        .find_map(|l| {
            l.trim()
                .strip_prefix("μs:")
                .and_then(|s| s.trim().parse::<u64>().ok())
        });
    if !timeout.status.success() || !normalized.status.success() || actual != Some(deadline * 1000)
    {
        return Err(io::Error::other("service deadline readback mismatch"));
    }
    if landlock_abi() < 6 {
        emit(&Boundary::verified(
            resources,
            landlock_abi(),
            false,
            false,
            true,
        ))?;
        return Ok(());
    }
    // This additional filter closes the unconnected UDP path. It is installed
    // on this single-threaded runner and inherited by the helper and probe.
    deny_inet_sockets()?;
    let binary_dir = std::env::current_exe()?
        .parent()
        .ok_or_else(|| invalid("binary directory"))?
        .to_owned();
    let confine = binary_dir.join("ditto-confine");
    let probe = binary_dir.join("ditto-test-probe");
    let workspace = root.join("workspace");
    let outside = if kind == "network" {
        // The listener lives at a short, manager-visible runtime path. Using
        // a long checkout path here would fail at sun_path before policy ran.
        root.join("denied.sock").canonicalize()?
    } else {
        root.join("sentinel")
    };
    let (ours, theirs) = UnixStream::pair()?;
    ours.set_read_timeout(Some(Duration::from_secs(5)))?;
    let fd = theirs.as_raw_fd();
    let mut command = Command::new(confine);
    command.args(["--status-fd", "3"]);
    for path in [
        Path::new("/usr"),
        Path::new("/lib"),
        Path::new("/lib64"),
        &probe,
    ] {
        if path.exists() {
            command.arg("--read").arg(path);
        }
    }
    command
        .arg("--write")
        .arg(&workspace)
        .arg("--cwd")
        .arg(&workspace)
        .args(["--env", "LANG=C.UTF-8", "--env", "PATH=/usr/bin"])
        .arg("--")
        .arg(probe)
        .arg(kind)
        .arg(&workspace)
        .arg(outside)
        .arg(launcher.to_string())
        .env_clear()
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    // SAFETY: pass only our private attestation channel as fd 3. The confine
    // helper closes this descriptor in the probe before exec.
    unsafe {
        command.pre_exec(move || {
            if libc::dup2(fd, 3) < 0 {
                return Err(io::Error::last_os_error());
            }
            Ok(())
        });
    }
    let mut child = command.spawn()?;
    drop(theirs);
    let stdout = bounded_read(child.stdout.take().ok_or_else(|| invalid("stdout"))?);
    let stderr = bounded_read(child.stderr.take().ok_or_else(|| invalid("stderr"))?);
    let mut status = String::new();
    // The attestation channel is capped separately from probe stdout.
    let handshake = ours.take(4097).read_to_string(&mut status);
    let attested = handshake.is_ok()
        && status.len() <= 4096
        && serde_json::from_str::<serde_json::Value>(&status)
            .ok()
            .is_some_and(|v| {
                v["confined"] == true
                    && v["landlock_abi"].as_i64().is_some_and(|v| v >= 6)
                    && v["seccomp"] == "connect-broker"
                    && v["session_bus_proxy"] == false
            });
    emit(&Boundary::verified(
        resources,
        landlock_abi(),
        attested,
        true,
        true,
    ))?;
    if !attested {
        child.kill()?;
    }
    let started = Instant::now();
    let status = loop {
        if let Some(status) = child.try_wait()? {
            break status;
        }
        // RuntimeMaxSec is the authoritative deadline. Leave time for the
        // manager's timer and stop sequence before this last-resort watchdog;
        // killing the probe first would incorrectly record SERVICE_RESULT=success.
        if process_start(launcher).as_ref() != Some(original_start)
            || started.elapsed() >= Duration::from_millis(deadline + 5_000)
        {
            child.kill()?;
            break child.wait()?;
        }
        thread::sleep(Duration::from_millis(20));
    };
    let output = format!(
        "{}{}",
        stdout.join().unwrap_or_default(),
        stderr.join().unwrap_or_default()
    );
    emit(&Completion {
        exit_code: status.code(),
        output,
    })
}

fn stop(unit: &str, child: &mut Child) {
    let _ = ctl(&[
        "kill",
        "--signal=KILL",
        "--kill-whom=all",
        &format!("{unit}.service"),
    ]);
    let _ = child.kill();
    let _ = child.wait();
}

fn run(kind: &str, deadline: u64) -> io::Result<Report> {
    let started = Instant::now();
    let mut random = [0u8; 12];
    fs::File::open("/dev/urandom")?.read_exact(&mut random)?;
    let key: String = random.iter().map(|b| format!("{b:02x}")).collect();
    let unit = format!("ditto-generated-test-{key}");
    // The caller may have a private /tmp mount that the user service manager
    // cannot see. Use the shared checkout's diagnostic data area, never a
    // formal Profile/plugin data path. Each run owns only its random directory.
    let workspace_parent = std::env::current_dir()?.join("artifacts/g3/workspaces");
    fs::create_dir_all(&workspace_parent)?;
    let root = workspace_parent.canonicalize()?.join(&unit);
    fs::DirBuilder::new().mode(0o700).create(&root)?;
    let runtime = std::env::var_os("XDG_RUNTIME_DIR")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| format!("/run/user/{}", unsafe { libc::geteuid() }).into());
    let socket_directory = runtime.join(format!("ditto-g3-probe-{key}"));
    let result = (|| {
        fs::create_dir(root.join("workspace"))?;
        fs::write(root.join("sentinel"), b"unchanged")?;
        fs::DirBuilder::new()
            .mode(0o700)
            .create(&socket_directory)?;
        let socket_path = socket_directory.join("denied.sock");
        let _denied_socket = UnixListener::bind(&socket_path)?;
        symlink(&socket_path, root.join("denied.sock"))?;
        symlink(root.join("sentinel"), root.join("workspace/escape-link"))?;
        let exe = std::env::current_exe()?;
        let mut command = Command::new("/usr/bin/systemd-run");
        command
            .args([
                "--user",
                "--quiet",
                "--wait",
                "--pipe",
                "--service-type=exec",
            ])
            .arg(format!("--unit={unit}"))
            .args([
                "-p",
                "MemoryMax=512M",
                "-p",
                "MemorySwapMax=0",
                "-p",
                "CPUQuota=100%",
                "-p",
                "TasksMax=64",
                "-p",
                "OOMPolicy=kill",
                "-p",
                "KillMode=control-group",
                "-p",
                "TimeoutStopSec=1s",
                "-p",
                "NoNewPrivileges=yes",
            ])
            .args(["-p", &format!("RuntimeMaxSec={deadline}ms")])
            .args([
                "-p",
                &format!(
                    "ExecStopPost={} __service-result {}",
                    unit_quote(&exe.to_string_lossy()),
                    unit_quote(&root.to_string_lossy())
                ),
            ]);
        if let Some(value) = std::env::var_os("XDG_RUNTIME_DIR") {
            command.arg(format!(
                "--setenv=XDG_RUNTIME_DIR={}",
                value.to_string_lossy()
            ));
        }
        command
            .arg("--")
            .arg(exe)
            .arg("__runner")
            .arg(kind)
            .arg(&root)
            .arg(&unit)
            .arg(deadline.to_string())
            .arg(std::process::id().to_string())
            .arg(process_start(std::process::id()).ok_or_else(|| invalid("launcher identity"))?)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .env_remove("NOTIFY_SOCKET");
        let mut child = command.spawn()?;
        let stdout = bounded_read(child.stdout.take().ok_or_else(|| invalid("stdout"))?);
        let stderr = bounded_read(child.stderr.take().ok_or_else(|| invalid("stderr"))?);
        let mut interrupted = None;
        loop {
            if child.try_wait()?.is_some() {
                break;
            }
            if CANCELLED.load(Ordering::SeqCst)
                || started.elapsed() > Duration::from_millis(deadline + 10_000)
            {
                interrupted = Some(if CANCELLED.load(Ordering::SeqCst) {
                    "cancelled"
                } else {
                    "timed_out"
                });
                stop(&unit, &mut child);
                break;
            }
            thread::sleep(Duration::from_millis(20));
        }
        let output = stdout.join().unwrap_or_default();
        let diagnostics = stderr.join().unwrap_or_default();
        let mut lines = output.lines();
        let mut boundary: Boundary = lines
            .next()
            .and_then(|s| serde_json::from_str(s).ok())
            .unwrap_or_else(|| Boundary::unavailable("runner_did_not_attest"));
        let completion = lines
            .next()
            .and_then(|s| serde_json::from_str::<Completion>(s).ok());
        let observed = ctl(&[
            "show",
            &format!("{unit}.service"),
            "-p",
            "Result",
            "-p",
            "LoadState",
        ])
        .ok()
        .filter(|o| o.status.success())
        .and_then(|o| {
            let text = String::from_utf8_lossy(&o.stdout);
            if !text.lines().any(|l| l == "LoadState=loaded") {
                return None;
            }
            text.lines()
                .find_map(|l| l.strip_prefix("Result=").map(str::to_owned))
        })
        .unwrap_or_else(|| "not_observed".into());
        // systemd may GC a transient unit before a later show. ExecStopPost
        // retains SERVICE_RESULT outside the candidate writable workspace.
        let service_result = fs::read_to_string(root.join("unit-result"))
            .ok()
            .filter(|s| {
                [
                    "success",
                    "timeout",
                    "oom-kill",
                    "signal",
                    "exit-code",
                    "resources",
                    "protocol",
                    "start-limit-hit",
                ]
                .contains(&s.as_str())
            })
            .unwrap_or(observed);
        let outcome = interrupted
            .unwrap_or_else(|| {
                if boundary.enforcement != Enforcement::Full {
                    "unavailable"
                } else if service_result == "oom-kill" {
                    "oom"
                } else if service_result == "timeout" {
                    "timed_out"
                } else if completion.as_ref().is_some_and(|c| c.exit_code == Some(0)) {
                    "succeeded"
                } else {
                    "failed"
                }
            })
            .to_string();
        // Ensure even a successful probe cannot leave descendants behind.
        let _ = ctl(&["stop", &format!("{unit}.service")]);
        let cleanup_complete = boundary.resources.as_ref().is_some_and(|r| {
            let events = Path::new("/sys/fs/cgroup")
                .join(r.cgroup.trim_start_matches('/'))
                .join("cgroup.events");
            match fs::read_to_string(events) {
                Ok(s) => s.lines().any(|l| l == "populated 0"),
                Err(e) => e.kind() == io::ErrorKind::NotFound,
            }
        });
        if !cleanup_complete && boundary.enforcement == Enforcement::Full {
            boundary.enforcement = Enforcement::Partial;
            boundary.reasons.push("cleanup_not_verified".into());
        }
        let _ = ctl(&["reset-failed", &format!("{unit}.service")]);
        if fs::read(root.join("sentinel"))? != b"unchanged" {
            return Err(io::Error::other("outside sentinel modified"));
        }
        Ok(Report {
            format_version: 1,
            probe: kind.into(),
            unit: unit.clone(),
            boundary,
            outcome,
            service_result,
            completion,
            cleanup_complete,
            diagnostics,
            elapsed_ms: started.elapsed().as_millis(),
            candidate_activation_available: false,
        })
    })();
    if result.is_err() {
        let _ = ctl(&["stop", &format!("{unit}.service")]);
        let _ = ctl(&["reset-failed", &format!("{unit}.service")]);
    }
    let _ = fs::remove_dir_all(root);
    let _ = fs::remove_dir_all(socket_directory);
    result
}

fn unit_quote(text: &str) -> String {
    format!(
        "\"{}\"",
        text.replace('\\', "\\\\")
            .replace('"', "\\\"")
            .replace('%', "%%")
    )
}
fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.first().is_some_and(|s| s == "__service-result") {
        if args.len() != 2 || std::env::var_os("INVOCATION_ID").is_none() {
            std::process::exit(64);
        }
        let root = Path::new(&args[1]);
        if !root
            .file_name()
            .is_some_and(|s| s.to_string_lossy().starts_with("ditto-generated-test-"))
        {
            std::process::exit(64);
        }
        let result = std::env::var("SERVICE_RESULT").unwrap_or_else(|_| "not_observed".into());
        if fs::write(root.join("unit-result"), result).is_err() {
            std::process::exit(1);
        }
        return;
    }
    if args.first().is_some_and(|s| s == "__runner") {
        if let Err(error) = runner(&args[1..]) {
            eprintln!("test-host runner: {error}");
            std::process::exit(1);
        }
        return;
    }
    let usage = "usage: ditto-test-host probe files|network|signals|spawn|memory|busy|timeout|spoof|orphan [--deadline-ms 100..120000]";
    let deadline = if args.len() == 2 {
        Some(DEFAULT_DEADLINE_MS)
    } else if args.len() == 4 && args[2] == "--deadline-ms" {
        args[3]
            .parse::<u64>()
            .ok()
            .filter(|n| (100..=MAX_DEADLINE_MS).contains(n))
    } else {
        None
    };
    let Some(deadline) = deadline.filter(|_| {
        args.first().is_some_and(|s| s == "probe")
            && args.get(1).is_some_and(|s| PROBES.contains(&s.as_str()))
    }) else {
        eprintln!("{usage}");
        std::process::exit(64);
    };
    // SAFETY: the signal handler only writes an atomic; main performs cleanup.
    unsafe {
        let mut action: libc::sigaction = std::mem::zeroed();
        action.sa_sigaction = cancel as *const () as usize;
        libc::sigemptyset(&mut action.sa_mask);
        for signal in [libc::SIGTERM, libc::SIGINT, libc::SIGHUP] {
            libc::sigaction(signal, &action, std::ptr::null_mut());
        }
    }
    let started = Instant::now();
    match run(&args[1], deadline) {
        Ok(report) => {
            let code = if report.outcome == "unavailable" {
                2
            } else if report.cleanup_complete && report.outcome == "succeeded" {
                0
            } else {
                1
            };
            let _ = emit(&report);
            std::process::exit(code);
        }
        Err(error) => {
            let _ = emit(&Report::unavailable(
                &args[1],
                &error.to_string(),
                started.elapsed().as_millis(),
            ));
            std::process::exit(2);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn early_failure_keeps_the_report_shape_without_inventing_execution_or_cleanup() {
        let report =
            serde_json::to_value(Report::unavailable("network", "setup failed", 1)).unwrap();
        assert!(report.as_object().unwrap().contains_key("completion"));
        assert_eq!(report["completion"], serde_json::Value::Null);
        assert_eq!(report["outcome"], "unavailable");
        assert_eq!(report["boundary"]["enforcement"], "unavailable");
        assert_eq!(report["unit"], "");
        assert_eq!(report["service_result"], "not_observed");
        assert_eq!(report["cleanup_complete"], false);
        assert_eq!(report["candidate_activation_available"], false);
    }
}
