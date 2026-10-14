//! Production fixed-template validation/preview. Only a bounded Description
//! enters the runner; the QML source is always taken from the compiled SDK.
use ditto_protocol::{generation::*, jcs};
use ditto_test_host::{deny_inet_sockets, landlock_abi, ResourceEvidence};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    fs,
    io::{self, BufRead, BufReader, Read, Write},
    os::{
        fd::AsRawFd,
        unix::{fs::DirBuilderExt, net::UnixStream, process::CommandExt},
    },
    path::{Path, PathBuf},
    process::{Command, Stdio},
    sync::{
        atomic::{AtomicBool, Ordering},
        mpsc,
    },
    thread,
    time::{Duration, Instant},
};
static CANCELLED: AtomicBool = AtomicBool::new(false);
extern "C" fn cancel(_: i32) {
    CANCELLED.store(true, Ordering::SeqCst);
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Input {
    artifact: GeneratedArtifact,
    work_root: PathBuf,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct NativePin {
    qt_prefix: PathBuf,
    qt_version: String,
    sha256: String,
}
#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct NativeResult {
    exec_blocked: bool,
    stages: Vec<StageEvidence>,
    preview_opened: bool,
    test_data: bool,
}
fn emit(v: Value) {
    let mut out = io::stdout().lock();
    let _ = writeln!(out, "{v}");
    let _ = out.flush();
}
fn ctl(args: &[&str]) -> io::Result<std::process::Output> {
    manager_command("/usr/bin/systemctl")
        .args(["--user", "--no-ask-password"])
        .args(args)
        .env_remove("NOTIFY_SOCKET")
        .output()
}
fn start_time(pid: u32) -> Option<String> {
    fs::read_to_string(format!("/proc/{pid}/stat"))
        .ok()?
        .rsplit_once(')')?
        .1
        .split_whitespace()
        .nth(19)
        .map(str::to_owned)
}
fn unavailable(reason: &str, deadline: u64) -> GenerationBoundary {
    GenerationBoundary {
        enforcement: Enforcement::Unavailable,
        policy: "generated-templates-v1".into(),
        landlock_abi: landlock_abi(),
        files: false,
        network: false,
        process_exec_blocked: false,
        memory_max: 0,
        cpu_max: String::new(),
        pids_max: 0,
        deadline_ms: deadline,
        cleanup_complete: false,
        reasons: vec![reason.into()],
        unit: None,
        cgroup: None,
        runner_pid: None,
    }
}
fn collect<R: Read + Send + 'static>(input: R) -> thread::JoinHandle<String> {
    thread::spawn(move || {
        let mut out = String::new();
        let _ = input.take(65536).read_to_string(&mut out);
        out
    })
}

fn inside(args: &[String]) -> Result<(), Box<dyn std::error::Error>> {
    if args.len() != 6 {
        return Err("private runner arguments".into());
    }
    let root = Path::new(&args[0]);
    let unit = &args[1];
    let deadline: u64 = args[2].parse()?;
    let mode = &args[3];
    let launcher: u32 = args[4].parse()?;
    let launcher_start = &args[5];
    let resources = ResourceEvidence::read()?;
    if !resources.matches_policy() || !resources.cgroup.ends_with(&format!("/{unit}.service")) {
        return Err("cgroup mismatch".into());
    }
    let timeout = ctl(&[
        "show",
        &format!("{unit}.service"),
        "-p",
        "RuntimeMaxUSec",
        "--value",
    ])?;
    let normalized = Command::new("/usr/bin/systemd-analyze")
        .args(["timespan", String::from_utf8_lossy(&timeout.stdout).trim()])
        .output()?;
    let actual = String::from_utf8_lossy(&normalized.stdout)
        .lines()
        .find_map(|s| {
            s.trim()
                .strip_prefix("μs:")
                .and_then(|s| s.trim().parse::<u64>().ok())
        });
    if actual != Some(deadline * 1000) {
        return Err("deadline mismatch".into());
    }
    let mut boundary = unavailable("confinement_unavailable", deadline);
    boundary.unit = Some(format!("{unit}.service"));
    boundary.cgroup = Some(resources.cgroup.clone());
    boundary.memory_max = 512 * 1024 * 1024;
    boundary.cpu_max = resources.cpu_max.clone();
    boundary.pids_max = 64;
    if landlock_abi() < 6 {
        boundary.enforcement = Enforcement::Partial;
        boundary.reasons = vec!["landlock_abi_below_6".into()];
        emit(json!({"host_boundary":boundary,"cgroup":resources.cgroup}));
        return Ok(());
    }
    let description =
        Description::parse(&fs::read(root.join("description.json"))?).map_err(io::Error::other)?;
    if fs::read_to_string(root.join("Panel.qml"))?
        != description
            .inspect()
            .map_err(io::Error::other)?
            .template_source
    {
        return Err("template integrity".into());
    }
    let bin = std::env::current_exe()?
        .parent()
        .ok_or("binary directory")?
        .to_owned();
    let native = bin.join("ditto-generation-runner");
    let pin: NativePin = serde_json::from_slice(&fs::read(native.with_extension("json"))?)?;
    if pin.qt_version != "6.10.2"
        || !pin.qt_prefix.is_absolute()
        || jcs::sha256_hex(&fs::read(&native)?) != pin.sha256
    {
        return Err("native runner integrity".into());
    }
    deny_inet_sockets()?;
    let (ours, theirs) = UnixStream::pair()?;
    ours.set_read_timeout(Some(Duration::from_secs(5)))?;
    let fd = theirs.as_raw_fd();
    let tmp = root.join("tmp");
    fs::create_dir(&tmp)?;
    let mut command = Command::new(bin.join("ditto-confine"));
    command.args(["--status-fd", "3"]);
    for path in [
        Path::new("/usr"),
        Path::new("/lib"),
        Path::new("/lib64"),
        Path::new("/etc/fonts"),
        Path::new("/dev/urandom"),
        &pin.qt_prefix,
        &native,
        &root.join("description.json"),
        &root.join("Panel.qml"),
    ] {
        if path.exists() {
            command.arg("--read").arg(path);
        }
    }
    command
        .arg("--write")
        .arg(&tmp)
        .args(["--write", "/dev/null"])
        .arg("--cwd")
        .arg(&tmp);
    for entry in [
        format!("HOME={}", tmp.display()),
        format!("XDG_CACHE_HOME={}", tmp.display()),
        "LANG=C.UTF-8".into(),
        "QT_QUICK_BACKEND=software".into(),
        "QSG_RENDER_LOOP=basic".into(),
        "QT_ACCESSIBILITY=0".into(),
        format!("LD_LIBRARY_PATH={}/lib", pin.qt_prefix.display()),
        format!("QML_IMPORT_PATH={}/qml", pin.qt_prefix.display()),
    ] {
        command.args(["--env", &entry]);
    }
    if mode == "preview" {
        let runtime = std::env::var("XDG_RUNTIME_DIR")?;
        let display = std::env::var("WAYLAND_DISPLAY")?;
        if Path::new(&display).components().count() != 1 {
            return Err("invalid Wayland endpoint".into());
        }
        let socket = Path::new(&runtime).join(&display);
        command.arg("--unix").arg(socket);
        for env in [
            "QT_QPA_PLATFORM=wayland".into(),
            format!("XDG_RUNTIME_DIR={runtime}"),
            format!("WAYLAND_DISPLAY={display}"),
        ] {
            command.args(["--env", &env]);
        }
    } else {
        command.args(["--env", "QT_QPA_PLATFORM=offscreen"]);
    }
    command
        .arg("--")
        .arg(native)
        .arg(mode)
        .arg(root.join("description.json"))
        .arg(root.join("Panel.qml"))
        .env_clear()
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
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
    let stdout = child.stdout.take().ok_or("native output")?;
    let stderr = collect(child.stderr.take().ok_or("native diagnostics")?);
    let (tx, rx) = mpsc::channel();
    thread::spawn(move || {
        let mut bytes = 0;
        for line in BufReader::new(stdout).lines().map_while(Result::ok) {
            bytes += line.len();
            if bytes > 65536 {
                break;
            }
            if tx.send(line).is_err() {
                break;
            }
        }
    });
    let mut handshake = String::new();
    ours.take(4097).read_to_string(&mut handshake)?;
    let status: Value = serde_json::from_str(&handshake)?;
    if handshake.len() > 4096
        || status["confined"] != true
        || status["seccomp"] != "connect-broker"
        || status["session_bus_proxy"] != false
    {
        child.kill()?;
        return Err("confinement handshake".into());
    }
    boundary.enforcement = Enforcement::Partial;
    boundary.runner_pid = Some(child.id());
    boundary.files = true;
    boundary.network = true;
    boundary.reasons.clear();
    emit(json!({"host_boundary":boundary,"cgroup":resources.cgroup}));
    let started = Instant::now();
    let mut result = None;
    let consume = |line: String, result: &mut Option<NativeResult>| {
        if let Ok(v) = serde_json::from_str::<Value>(&line) {
            if v.get("native_result").is_some() {
                *result = serde_json::from_value(v["native_result"].clone()).ok();
            }
            if v.get("stage_timing").is_some() {
                emit(json!({"stage_timing":v["stage_timing"]}));
            }
            if v["phase"].as_str().is_some_and(|s| {
                [
                    "syntax",
                    "contract",
                    "load",
                    "focus",
                    "interaction",
                    "preview_opened",
                ]
                .contains(&s)
            }) {
                emit(json!({"phase":v["phase"],"progress":v["progress"]}));
            }
        }
    };
    loop {
        while let Ok(line) = rx.try_recv() {
            consume(line, &mut result);
        }
        if child.try_wait()?.is_some() {
            break;
        }
        if start_time(launcher).as_ref() != Some(launcher_start)
            || started.elapsed() >= Duration::from_millis(deadline)
        {
            child.kill()?;
            let _ = child.wait();
            break;
        }
        thread::sleep(Duration::from_millis(10));
    }
    for _ in 0..10 {
        while let Ok(line) = rx.try_recv() {
            consume(line, &mut result);
        }
        thread::sleep(Duration::from_millis(2));
    }
    emit(json!({"native_completion":result,"diagnostics":stderr.join().unwrap_or_default()}));
    Ok(())
}

fn run(mode: &str, input: Input) -> Result<GenerationValidation, Box<dyn std::error::Error>> {
    let expected = bundle(&input.artifact.description).map_err(io::Error::other)?;
    if expected.3 != input.artifact.bundle_sha256
        || expected.1 != input.artifact.source_files
        || expected.0 != input.artifact.manifest
    {
        return Err("candidate bundle integrity".into());
    }
    fs::create_dir_all(&input.work_root)?;
    let root = input
        .work_root
        .canonicalize()?
        .join(ditto_protocol::ids::new("validation"));
    fs::DirBuilder::new().mode(0o700).create(&root)?;
    let deadline = if mode == "preview" { 30000 } else { 15000 };
    let unit = format!(
        "ditto-generation-{}",
        ditto_protocol::ids::ulid().to_ascii_lowercase()
    );
    let outcome = (|| {
        fs::write(
            root.join("description.json"),
            serde_json::to_vec(&input.artifact.description)?,
        )?;
        fs::write(
            root.join("Panel.qml"),
            input
                .artifact
                .description
                .inspect()
                .map_err(io::Error::other)?
                .template_source,
        )?;
        let mut command = manager_command("/usr/bin/systemd-run");
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
            .args(["-p", &format!("RuntimeMaxSec={deadline}ms")]);
        for key in ["XDG_RUNTIME_DIR", "WAYLAND_DISPLAY"] {
            if let Ok(v) = std::env::var(key) {
                command.arg(format!("--setenv={key}={v}"));
            }
        }
        command
            .arg("--")
            .arg(std::env::current_exe()?)
            .arg("__runner")
            .arg(&root)
            .arg(&unit)
            .arg(deadline.to_string())
            .arg(mode)
            .arg(std::process::id().to_string())
            .arg(start_time(std::process::id()).ok_or("launcher identity")?)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .env_remove("NOTIFY_SOCKET");
        let mut child = command.spawn()?;
        let stdout = child.stdout.take().ok_or("host output")?;
        let stderr = collect(child.stderr.take().ok_or("host error")?);
        let (tx, rx) = mpsc::channel();
        thread::spawn(move || {
            let mut n = 0;
            for line in BufReader::new(stdout).lines().map_while(Result::ok) {
                n += line.len();
                if n > 128 * 1024 {
                    break;
                }
                if tx.send(line).is_err() {
                    break;
                }
            }
        });
        let started = Instant::now();
        let mut boundary = unavailable("runner_did_not_attest", deadline);
        let mut cgroup = None;
        let mut completion = None;
        let native_diagnostics = std::cell::RefCell::new(Vec::<String>::new());
        let consume = |line: String,
                       boundary: &mut GenerationBoundary,
                       cgroup: &mut Option<String>,
                       completion: &mut Option<NativeResult>| {
            if let Ok(v) = serde_json::from_str::<Value>(&line) {
                if let Ok(b) =
                    serde_json::from_value::<GenerationBoundary>(v["host_boundary"].clone())
                {
                    *boundary = b;
                    *cgroup = v["cgroup"].as_str().map(str::to_owned);
                }
                if v.get("native_completion").is_some() {
                    *completion = serde_json::from_value(v["native_completion"].clone()).ok();
                    if let Some(text) = v["diagnostics"].as_str() {
                        if !text.is_empty() {
                            native_diagnostics
                                .borrow_mut()
                                .push(text.chars().take(8192).collect());
                        }
                    }
                }
                if v.get("phase").is_some() {
                    emit(json!({"phase":v["phase"],"progress":v["progress"]}));
                }
                if v.get("stage_timing").is_some() {
                    // Keep telemetry in existing diagnostics, separate from
                    // deterministic error fingerprints and boundary evidence.
                    native_diagnostics
                        .borrow_mut()
                        .push(format!("stage_timing:{}", v["stage_timing"]));
                }
            }
        };
        loop {
            while let Ok(line) = rx.try_recv() {
                consume(line, &mut boundary, &mut cgroup, &mut completion);
            }
            if child.try_wait()?.is_some() {
                break;
            }
            if CANCELLED.load(Ordering::SeqCst)
                || !core_alive()
                || started.elapsed() >= Duration::from_millis(deadline + 10000)
            {
                let _ = ctl(&[
                    "kill",
                    "--signal=KILL",
                    "--kill-whom=all",
                    &format!("{unit}.service"),
                ]);
                let _ = child.kill();
                let _ = child.wait();
                break;
            }
            thread::sleep(Duration::from_millis(10));
        }
        for _ in 0..10 {
            while let Ok(line) = rx.try_recv() {
                consume(line, &mut boundary, &mut cgroup, &mut completion);
            }
            thread::sleep(Duration::from_millis(2));
        }
        let diagnostics = stderr.join().unwrap_or_default();
        let _ = ctl(&["stop", &format!("{unit}.service")]);
        boundary.cleanup_complete = cgroup.is_some_and(|s| {
            if !s.ends_with(&format!("/{unit}.service")) {
                return false;
            }
            match fs::read_to_string(
                Path::new("/sys/fs/cgroup")
                    .join(s.trim_start_matches('/'))
                    .join("cgroup.events"),
            ) {
                Ok(v) => v.lines().any(|l| l == "populated 0"),
                Err(e) => e.kind() == io::ErrorKind::NotFound,
            }
        });
        let _ = ctl(&["reset-failed", &format!("{unit}.service")]);
        let mut stages = VALIDATION_STAGES
            .iter()
            .map(|s| StageEvidence {
                stage: *s,
                result: StageResult::NotRun,
                diagnostic: "host_unavailable".into(),
            })
            .collect();
        let mut preview = false;
        if let Some(n) = completion {
            boundary.process_exec_blocked = n.exec_blocked;
            stages = n.stages;
            preview = n.preview_opened;
        }
        if boundary.files
            && boundary.network
            && boundary.process_exec_blocked
            && boundary.cleanup_complete
        {
            boundary.enforcement = Enforcement::Full;
        } else if boundary.reasons.is_empty() {
            boundary.reasons.push(if diagnostics.is_empty() {
                "native_runner_incomplete".into()
            } else {
                "native_runner_unavailable".into()
            });
        }
        Ok::<_, Box<dyn std::error::Error>>(GenerationValidation {
            bundle_sha256: input.artifact.bundle_sha256.clone(),
            boundary,
            stages,
            test_data: true,
            preview_opened: preview,
            diagnostics: {
                let mut all = native_diagnostics.into_inner();
                if !diagnostics.is_empty() {
                    all.push(diagnostics.chars().take(8192).collect());
                }
                all
            },
        })
    })();
    if outcome.is_err() {
        let _ = ctl(&["stop", &format!("{unit}.service")]);
    }
    let _ = fs::remove_dir_all(root);
    outcome
}
fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.first().is_some_and(|s| s == "__runner") {
        if let Err(e) = inside(&args[1..]) {
            eprintln!("generation runner: {e}");
            std::process::exit(1);
        }
        return;
    }
    if args.len() != 1 || !["validate", "preview"].contains(&args[0].as_str()) {
        eprintln!("usage: ditto-generation-host validate|preview < Core-worker-input.json");
        std::process::exit(64);
    }
    unsafe {
        let mut action: libc::sigaction = std::mem::zeroed();
        action.sa_sigaction = cancel as *const () as usize;
        libc::sigemptyset(&mut action.sa_mask);
        for s in [libc::SIGTERM, libc::SIGINT, libc::SIGHUP] {
            libc::sigaction(s, &action, std::ptr::null_mut());
        }
    }
    let result = (|| {
        let mut bytes = Vec::new();
        io::stdin().take(256 * 1024).read_to_end(&mut bytes)?;
        let input: Input = serde_json::from_slice(&bytes)?;
        run(&args[0], input)
    })();
    match result {
        Ok(v) => emit(json!({"result":v})),
        Err(e) => {
            emit(json!({"error":format!("generation.host_unavailable: {e}")}));
            std::process::exit(2);
        }
    }
}

fn manager_command(binary: &str) -> Command {
    let mut c = Command::new(binary);
    c.env(
        "DBUS_SESSION_BUS_ADDRESS",
        format!("unix:path=/run/user/{}/bus", unsafe { libc::getuid() }),
    );
    c
}

fn core_alive() -> bool {
    let Ok(witness) = std::env::var("DITTO_JOB_CORE_WITNESS") else {
        return true;
    };
    let Some((pid, expected)) = witness.split_once(':') else {
        return false;
    };
    pid.parse::<u32>().ok().and_then(start_time).as_deref() == Some(expected)
}
