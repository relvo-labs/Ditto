//! Lifecycle contract tests L-05, L-06, L-07, L-09 and L-10 (plan/03/06 §3,
//! EX1-08) against the real binaries: `ditto-core` in normal mode (no shared
//! development token) on the fixture compositor, the real `ditto-hostd`
//! (fault-injection bundle) started by Core's supervision, the built-in tasks
//! service, and — for L-10 — the Agent stand-in, all started through Core's
//! controlled launcher. The test itself talks to Core through
//! `tests/g1/lib/bridge.mjs`, a pass-through Core launches as a CLI client.
//! Each test states the table's positive case and its fault-injection
//! negative; neither is weakened to fit what the code does.
//!
//! Needs the `fault-injection` build of Core and the test bundle of hostd:
//!
//! ```text
//! DITTO_HOST_FAULT_ENABLE=1 pnpm --filter @ditto/host-runtime build
//! pnpm --filter @ditto/host-sdk build && bash scripts/build-builtin-packages.sh
//! cargo test -p ditto-core --features fault-injection --test lifecycle
//! ```
//!
//! `node` is taken from `DITTO_NODE`, else from `PATH`; the packages from
//! `DITTO_BUILTIN_PACKAGES`, else `target/ditto-packages`. A missing
//! prerequisite fails the test with what to build; it is never skipped.
#![cfg(feature = "fault-injection")]

use std::{
    collections::HashMap,
    io::{BufRead, BufReader, Write},
    os::unix::{fs::MetadataExt, net::UnixStream},
    path::{Path, PathBuf},
    process::{Child, Command},
    sync::{
        atomic::{AtomicU64, Ordering},
        mpsc, Arc, Mutex,
    },
    thread,
    time::{Duration, Instant},
};

use serde_json::{json, Value};

const PROTOCOL: &str = ditto_protocol::PROTOCOL_VERSION;
const TASKS_LIST: &str = "desktop.tasks.list";

// ---- prerequisites -------------------------------------------------------------

struct Prerequisites {
    node: PathBuf,
    hostd: PathBuf,
    packages: PathBuf,
    bridge: PathBuf,
    standin: PathBuf,
}

fn workspace() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .canonicalize()
        .expect("workspace root")
}

fn prerequisites() -> Prerequisites {
    let workspace = workspace();
    let node = std::env::var_os("DITTO_NODE")
        .map(PathBuf::from)
        .or_else(|| {
            std::env::split_paths(&std::env::var_os("PATH").unwrap_or_default())
                .map(|directory| directory.join("node"))
                .find(|candidate| candidate.is_file())
        })
        .expect("node is not on PATH (or DITTO_NODE): these tests run the real ditto-hostd")
        .canonicalize()
        .expect("node path");
    let hostd = workspace.join("packages/host-runtime/dist/ditto-hostd-fault.mjs");
    assert!(
        hostd.is_file(),
        "{} is missing: DITTO_HOST_FAULT_ENABLE=1 pnpm --filter @ditto/host-runtime build",
        hostd.display()
    );
    let packages = std::env::var_os("DITTO_BUILTIN_PACKAGES")
        .map(PathBuf::from)
        .unwrap_or_else(|| workspace.join("target/ditto-packages"));
    assert!(
        std::fs::read_dir(&packages).is_ok_and(|entries| entries.flatten().any(|e| {
            let name = e.file_name();
            let name = name.to_string_lossy();
            name.starts_with("ditto.svc.tasks-") && name.ends_with(".dittopkg")
        })),
        "{} has no ditto.svc.tasks package: bash scripts/build-builtin-packages.sh",
        packages.display()
    );
    let prerequisites = Prerequisites {
        node,
        hostd,
        packages,
        bridge: workspace.join("tests/g1/lib/bridge.mjs"),
        standin: workspace.join("tests/g1/fixtures/agent-standin/standin.mjs"),
    };
    // Launch specifications are split on whitespace.
    for path in [
        &prerequisites.node,
        &prerequisites.hostd,
        &prerequisites.packages,
        &prerequisites.bridge,
    ] {
        assert!(
            !path.display().to_string().contains(char::is_whitespace),
            "{} contains whitespace; launch specifications cannot carry it",
            path.display()
        );
    }
    prerequisites
}

// ---- processes -----------------------------------------------------------------

fn signal(pid: u32, signal: i32) {
    // SAFETY: kill has no memory preconditions; a stale pid only fails.
    unsafe { libc::kill(pid as i32, signal) };
}

/// Running, i.e. it exists and is not a zombie.
fn running(pid: u32) -> bool {
    match std::fs::read_to_string(format!("/proc/{pid}/stat")) {
        Ok(stat) => stat
            .rsplit_once(')')
            .and_then(|(_, rest)| rest.split_whitespace().next())
            .is_some_and(|state| state != "Z" && state != "X"),
        Err(_) => false,
    }
}

fn children(parent: u32) -> Vec<u32> {
    let Ok(entries) = std::fs::read_dir("/proc") else {
        return vec![];
    };
    entries
        .filter_map(|entry| entry.ok()?.file_name().to_str()?.parse::<u32>().ok())
        .filter(|pid| {
            std::fs::read_to_string(format!("/proc/{pid}/stat"))
                .ok()
                .and_then(|stat| {
                    let (_, rest) = stat.rsplit_once(')')?;
                    rest.split_whitespace().nth(1)?.parse::<u32>().ok()
                })
                == Some(parent)
        })
        .collect()
}

fn command_line(pid: u32) -> String {
    std::fs::read(format!("/proc/{pid}/cmdline"))
        .map(|bytes| String::from_utf8_lossy(&bytes).replace('\0', " "))
        .unwrap_or_default()
}

/// Poll `probe` every `step` until it returns something or `timeout` passes.
fn wait_for<T>(
    timeout: Duration,
    step: Duration,
    mut probe: impl FnMut() -> Option<T>,
) -> Option<T> {
    let deadline = Instant::now() + timeout;
    loop {
        if let Some(value) = probe() {
            return Some(value);
        }
        if Instant::now() >= deadline {
            return None;
        }
        thread::sleep(step);
    }
}

// ---- the test's connection (through the bridge) -----------------------------------

struct Peer {
    writer: Mutex<UnixStream>,
    pending: Arc<Mutex<HashMap<String, mpsc::Sender<Value>>>>,
    next: AtomicU64,
}

impl Peer {
    fn connect(socket: &Path) -> Arc<Self> {
        let stream = wait_for(Duration::from_secs(20), Duration::from_millis(20), || {
            UnixStream::connect(socket).ok()
        })
        .unwrap_or_else(|| panic!("the bridge at {} never accepted", socket.display()));
        let pending: Arc<Mutex<HashMap<String, mpsc::Sender<Value>>>> = Arc::default();
        {
            let pending = Arc::clone(&pending);
            let reader = stream.try_clone().unwrap();
            thread::spawn(move || {
                let mut reader = BufReader::new(reader);
                let mut line = String::new();
                while reader.read_line(&mut line).unwrap_or(0) > 0 {
                    let message: Value = serde_json::from_str(&line).unwrap_or(Value::Null);
                    line.clear();
                    if message.get("method").is_some() {
                        continue; // events; nothing here follows them
                    }
                    if let Some(id) = message["id"].as_str() {
                        if let Some(waiter) = pending.lock().unwrap().remove(id) {
                            let _ = waiter.send(message);
                        }
                    }
                }
            });
        }
        Arc::new(Self {
            writer: Mutex::new(stream),
            pending,
            next: AtomicU64::new(0),
        })
    }

    /// One call; the whole JSON-RPC response (`result` or `error`).
    fn call(&self, method: &str, mut params: Value, operation_id: Option<&str>) -> Value {
        let id = format!("t-{}", self.next.fetch_add(1, Ordering::SeqCst) + 1);
        params["_meta"] = json!({"protocol_version": PROTOCOL, "deadline_ms": 20000, "operation_id": operation_id});
        let (waiter, answer) = mpsc::channel();
        self.pending.lock().unwrap().insert(id.clone(), waiter);
        {
            let mut stream = self.writer.lock().unwrap();
            writeln!(
                stream,
                "{}",
                json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params})
            )
            .expect("write to the bridge");
        }
        answer
            .recv_timeout(Duration::from_secs(25))
            .unwrap_or_else(|_| panic!("{method} got no answer in 25 s"))
    }

    fn result(&self, method: &str, params: Value) -> Value {
        let answer = self.call(method, params, None);
        assert!(answer.get("error").is_none(), "{method}: {answer}");
        answer["result"].clone()
    }
}

// ---- the fixture -------------------------------------------------------------------

/// `{work}` in any of these strings becomes the fixture's work directory.
#[derive(Default)]
struct Setup {
    /// `DITTO_FAULT` for Core.
    core_fault: Option<String>,
    /// `DITTO_HOST_FAULT` for every hostd Core starts.
    host_fault: Option<String>,
    /// Agent stand-ins: the arguments after `standin.mjs`.
    standins: Vec<String>,
}

struct Fixture {
    root: PathBuf,
    work: PathBuf,
    core: Child,
    cli: Arc<Peer>,
}

static FIXTURES: AtomicU64 = AtomicU64::new(0);

impl Fixture {
    fn start(label: &str, setup: Setup) -> Self {
        let tools = prerequisites();
        // A socket path must fit in sun_path; keep the root short.
        let base = std::env::temp_dir();
        let base = if base.as_os_str().len() > 40 {
            PathBuf::from("/tmp")
        } else {
            base
        };
        let root = base.join(format!(
            "dl-{label}-{}-{}",
            std::process::id(),
            FIXTURES.fetch_add(1, Ordering::SeqCst)
        ));
        let _ = std::fs::remove_dir_all(&root);
        let work = root.join("w");
        std::fs::create_dir_all(&work).unwrap();
        std::fs::create_dir_all(root.join("run")).unwrap();
        let bridge_socket = work.join("bridge.sock");
        let node = tools.node.display().to_string();
        let mut command = Command::new(env!("CARGO_BIN_EXE_ditto-core"));
        command
            .args(["serve", "--compositor", "fixture", "--builtin-packages"])
            .arg(&tools.packages)
            .arg("--hostd")
            .arg(format!("hostd 0.2.0 {node} {}", tools.hostd.display()))
            .arg("--launch")
            .arg(format!(
                "dittoctl 0.2.0 {node} {} {}",
                tools.bridge.display(),
                bridge_socket.display()
            ));
        let work_text = work.display().to_string();
        let expand = |text: &str| text.replace("{work}", &work_text);
        for arguments in &setup.standins {
            command.arg("--launch").arg(format!(
                "agent 0.2.0 {node} {} {}",
                tools.standin.display(),
                expand(arguments)
            ));
        }
        command
            .env("DITTO_DATA_DIR", root.join("store"))
            .env("DITTO_RUNTIME_DIR", root.join("run"))
            .env("DITTO_SYSTEM", "none")
            .env_remove("DITTO_DEV_TOKEN")
            .env_remove("WAYFIRE_SOCKET")
            .env_remove("SWAYSOCK")
            .env_remove("DITTO_LAUNCH_SCOPE_PREFIX")
            .env_remove("DITTO_REQUIRE_QUOTA")
            .env_remove("DITTO_FAULT")
            .env_remove("DITTO_HOST_FAULT")
            .stdout(std::fs::File::create(root.join("core.out")).unwrap())
            .stderr(std::fs::File::create(root.join("core.log")).unwrap());
        if let Some(fault) = &setup.core_fault {
            command.env("DITTO_FAULT", expand(fault));
        }
        if let Some(fault) = &setup.host_fault {
            command.env("DITTO_HOST_FAULT", expand(fault));
        }
        let core = command.spawn().expect("ditto-core starts");
        // Constructed before connecting, so a bridge that never comes up
        // still has Core and its clients cleaned up by Drop.
        let mut fixture = Self {
            root,
            work,
            core,
            cli: Arc::new(Peer {
                writer: Mutex::new(UnixStream::pair().unwrap().0),
                pending: Arc::default(),
                next: AtomicU64::new(0),
            }),
        };
        fixture.cli = Peer::connect(&bridge_socket);
        fixture
    }

    fn log(&self) -> String {
        std::fs::read_to_string(self.root.join("core.log")).unwrap_or_default()
    }

    /// JSON lines of the log (Core's and every launched client's stderr).
    fn log_lines(&self) -> Vec<Value> {
        self.log()
            .lines()
            .filter_map(|line| serde_json::from_str(line).ok())
            .collect()
    }

    fn path(&self, name: &str) -> PathBuf {
        self.work.join(name)
    }

    fn wait_held(&self) {
        let held = self.path("release.held");
        assert!(
            wait_for(Duration::from_secs(30), Duration::from_millis(5), || held
                .exists()
                .then_some(()))
            .is_some(),
            "the coordinator never reached the hold point"
        );
    }

    fn release(&self) {
        std::fs::write(self.path("release"), b"go").unwrap();
        let held = self.path("release.held");
        assert!(
            wait_for(Duration::from_secs(10), Duration::from_millis(5), || {
                (!held.exists()).then_some(())
            })
            .is_some(),
            "the coordinator did not go on after the release"
        );
    }

    fn availability(&self, capability: &str) -> (bool, Option<String>) {
        let listing = self.cli.result("desktop.capabilities.list", json!({}));
        let item = listing["capabilities"]
            .as_array()
            .unwrap()
            .iter()
            .find(|item| item["capability_id"] == capability)
            .cloned()
            .unwrap_or_else(|| panic!("{capability} is not in the catalog"));
        let availability = &item["availability"];
        let available =
            availability["kind"] == "always" || availability["available"].as_bool() == Some(true);
        (available, availability["reason"].as_str().map(String::from))
    }

    fn wait_available(&self, capability: &str, timeout: Duration) {
        assert!(
            wait_for(timeout, Duration::from_millis(50), || self
                .availability(capability)
                .0
                .then_some(()))
            .is_some(),
            "{capability} did not become available within {timeout:?}"
        );
    }

    /// (head revision, document) of the active profile.
    fn profile(&self) -> (String, Value) {
        let got = self.cli.result("desktop.profiles.get", json!({}));
        (
            got["profile"]["head_revision"]
                .as_str()
                .unwrap()
                .to_string(),
            got["document"].clone(),
        )
    }

    /// The tasks service entry and its configuration.
    fn tasks_entry(&self) -> (String, Value) {
        let (_, document) = self.profile();
        let entry = document["slots"]["svc.tasks"]
            .as_str()
            .expect("the default profile binds svc.tasks")
            .to_string();
        let config = document["entries"]
            .as_array()
            .unwrap()
            .iter()
            .find(|item| item["entry_id"] == entry.as_str())
            .map(|item| item["config"].clone())
            .unwrap_or(Value::Null);
        (entry, config)
    }

    /// (hostd pid, generation) as Core's diagnostics read them.
    fn host(&self) -> (Option<u32>, Option<u64>) {
        let diagnostics = self.cli.result("desktop.plugins.diagnostics", json!({}));
        (
            diagnostics["host"]["process"]["pid"]
                .as_u64()
                .map(|pid| pid as u32),
            diagnostics["host"]["generation"].as_u64(),
        )
    }

    fn leases(&self) -> u64 {
        let diagnostics = self.cli.result("desktop.plugins.diagnostics", json!({}));
        diagnostics["core"]["leases"].as_u64().unwrap()
    }

    fn propose_config(&self, base: &str, after: Value, operation: Option<&str>) -> Value {
        let (entry, before) = self.tasks_entry();
        self.cli.call(
            "desktop.changes.propose",
            json!({"base_revision": base, "ops": [{"op": "set_entry_config", "entry_id": entry, "before": before, "after": after}]}),
            operation,
        )
    }

    /// A proposal on another thread (it blocks while the coordinator holds).
    fn propose_config_later(
        &self,
        base: &str,
        after: Value,
        operation: &str,
    ) -> thread::JoinHandle<Value> {
        let (entry, before) = self.tasks_entry();
        let cli = Arc::clone(&self.cli);
        let body = json!({"base_revision": base, "ops": [{"op": "set_entry_config", "entry_id": entry, "before": before, "after": after}]});
        let operation = operation.to_string();
        thread::spawn(move || cli.call("desktop.changes.propose", body, Some(&operation)))
    }

    fn change(&self, operation: &str) -> Value {
        self.cli.call(
            "desktop.changes.get",
            json!({"operation_id": operation}),
            None,
        )
    }

    /// Grant a todo.txt to the tasks entry and point the service at it.
    fn configure_todo(&self, todo: &Path) {
        let (entry, before) = self.tasks_entry();
        std::fs::write(todo, "(A) 既有的一項\n").unwrap();
        let grant = self.cli.result(
            "desktop.permissions.grant",
            json!({"subject": format!("host:{entry}"), "scope": "files:todo", "resource": todo.display().to_string(), "idempotency_key": "lifecycle-todo"}),
        );
        let (base, _) = self.profile();
        let mut after = if before.is_object() {
            before.clone()
        } else {
            json!({})
        };
        after["source"] = json!({"kind": "todo_txt", "path_grant": grant["grant_id"]});
        let change = self.cli.result(
            "desktop.changes.propose",
            json!({"base_revision": base, "ops": [{"op": "set_entry_config", "entry_id": entry, "before": before, "after": after}]}),
        );
        assert_eq!(
            change["state"], "committed",
            "configuring todo.txt: {change}"
        );
        assert!(
            wait_for(Duration::from_secs(10), Duration::from_millis(50), || {
                let listed = self.cli.call(TASKS_LIST, json!({}), None);
                listed.to_string().contains("既有的一項").then_some(())
            })
            .is_some(),
            "the tasks service never listed the granted todo.txt"
        );
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        // Launched clients first (a stand-in waiting at its gate does not
        // notice Core going away), then Core.
        for child in children(self.core.id()) {
            signal(child, libc::SIGKILL);
        }
        let _ = self.core.kill();
        let _ = self.core.wait();
        if thread::panicking() || std::env::var_os("DITTO_KEEP_FIXTURE").is_some() {
            eprintln!(
                "fixture kept for inspection: {} (core.log has Core's and hostd's lines)",
                self.root.display()
            );
            return;
        }
        let _ = Command::new("chmod")
            .arg("-R")
            .arg("u+w")
            .arg(&self.root)
            .status();
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

/// Core's fault: hold the coordinator in `prepared` for the next `count`
/// changes, until the test releases it (crate::fault, `hold=`).
fn hold(count: u32) -> String {
    format!("coordinator.after_state=prepared:hold={{work}}/release:{count}")
}

fn items_of(record: &Value) -> Vec<Value> {
    record["items"].as_array().cloned().unwrap_or_default()
}

// ---- L-05 ----------------------------------------------------------------------------

/// L-05 跨宿主斷線（prepare 後）. Positive: SIGKILL hostd once its prepare is
/// done → the change is `aborted`; the hostd capability is `unavailable`
/// within 500 ms (EX1-08: not at lease expiry); compositor capabilities keep
/// answering. Negative: a call to that capability sent right after the kill
/// answers `unavailable` at once instead of hanging.
#[test]
fn l05_hostd_killed_after_prepare_aborts_and_unbinds_within_500_ms() {
    let fixture = Fixture::start(
        "l05",
        Setup {
            core_fault: Some(hold(1)),
            ..Setup::default()
        },
    );
    fixture.wait_available(TASKS_LIST, Duration::from_secs(30));
    let (base, _) = fixture.profile();
    let (_, config_before) = fixture.tasks_entry();
    let (Some(pid), Some(generation)) = fixture.host() else {
        panic!("hostd is not running");
    };
    let proposal = fixture.propose_config_later(&base, json!({"demo": true}), "op-l05");
    fixture.wait_held();
    let held = fixture.change("op-l05");
    assert_eq!(held["result"]["state"], "prepared", "{held}");

    let killed = Instant::now();
    signal(pid, libc::SIGKILL);
    let concurrent = {
        let cli = Arc::clone(&fixture.cli);
        thread::spawn(move || {
            let sent = Instant::now();
            let answer = cli.call(TASKS_LIST, json!({}), None);
            (answer, sent.elapsed())
        })
    };
    let unavailable = wait_for(Duration::from_secs(5), Duration::from_millis(5), || {
        let (available, reason) = fixture.availability(TASKS_LIST);
        (!available).then(|| (killed.elapsed(), reason))
    });
    let (after, reason) = unavailable.expect("tasks.list stayed available after hostd died");
    eprintln!(
        "L-05 measured: unavailable {} ms after SIGKILL",
        after.as_millis()
    );
    assert!(
        after <= Duration::from_millis(500),
        "unavailable only after {after:?} (EX1-08: ≤ 500 ms)"
    );
    assert_eq!(reason.as_deref(), Some("host_unavailable"));

    let (answer, took) = concurrent.join().unwrap();
    assert_eq!(answer["error"]["name"], "unavailable", "{answer}");
    assert!(
        took < Duration::from_secs(2),
        "the call took {took:?}; it must not wait for its 20 s deadline"
    );

    // The compositor side answers while the change is still held.
    for capability in ["desktop.windows.list", "desktop.workspaces.list"] {
        let answer = fixture.cli.call(capability, json!({}), None);
        assert!(answer.get("result").is_some(), "{capability}: {answer}");
    }

    fixture.release();
    let record = proposal.join().unwrap();
    let record = &record["result"];
    assert_eq!(record["state"], "aborted", "{record}");
    assert_eq!(record["failure_key"], "change.participant_lost", "{record}");
    assert!(
        items_of(record)
            .iter()
            .any(|item| item["participant"] == "hostd" && item["status"] == "failed"),
        "the lost participant is not listed: {record}"
    );
    // Nothing was applied: same head, same configuration.
    let (head, _) = fixture.profile();
    assert_eq!(head, base);
    assert_eq!(fixture.tasks_entry().1, config_before);
    // Supervision brings hostd back under a new generation.
    fixture.wait_available(TASKS_LIST, Duration::from_secs(30));
    let (_, now) = fixture.host();
    assert!(
        now > Some(generation),
        "generation {now:?} after {generation}"
    );
}

// ---- L-06 ----------------------------------------------------------------------------

/// (size, mtime, inode): any write to the file — in place or by rename —
/// changes one of them.
fn file_identity(path: &Path) -> (u64, i64, i64, u64) {
    let metadata = std::fs::metadata(path).unwrap();
    (
        metadata.len(),
        metadata.mtime(),
        metadata.mtime_nsec(),
        metadata.ino(),
    )
}

/// L-06 交接階段終止 hostd. Positive: SIGKILL hostd while the tasks service
/// hands over (after its drain) → the change ends failed or partially
/// applied with every item listed; the restarted hostd does not replay the
/// external side effect that had completed (the todo.txt write count stays
/// at one). Negative: the restarted hostd is asked `participant.state` for
/// the same `change_id`, answers that it does not know it, and Core decides
/// the outcome from the readback.
#[test]
fn l06_hostd_killed_during_handoff_lists_items_and_replays_nothing() {
    let fixture = Fixture::start(
        "l06",
        Setup {
            // Two hand-overs belong to the todo.txt setup (the grant
            // re-syncs the entry, then its configuration changes); the third
            // is the change under test, which then waits after its drain.
            host_fault: Some("commit.after_drain:delay=4000:3".into()),
            ..Setup::default()
        },
    );
    fixture.wait_available(TASKS_LIST, Duration::from_secs(30));
    let todo = fixture.path("todo.txt");
    fixture.configure_todo(&todo);
    let marker = "L-06 已完成的外部寫入";
    let added = fixture.cli.result(
        "desktop.tasks.add",
        json!({"text": marker, "source": "file"}),
    );
    assert_eq!(added["text"], marker, "{added}");
    let written = std::fs::read_to_string(&todo).unwrap();
    assert_eq!(written.matches(marker).count(), 1, "{written}");
    let identity = file_identity(&todo);
    let (base, _) = fixture.profile();
    let (_, config_before) = fixture.tasks_entry();
    let (Some(pid), Some(generation)) = fixture.host() else {
        panic!("hostd is not running");
    };

    let drains = |hit: u64| {
        fixture.log_lines().into_iter().any(|line| {
            line["msg"] == "fault injected"
                && line["point"] == "commit.after_drain"
                && line["hit"] == hit
        })
    };
    // Only the hit that fires is logged; if the setup had used it, the
    // change under test would not be the one held.
    assert!(
        !drains(3),
        "the setup handed over more than twice; the fault's hit number is off"
    );
    let mut after = config_before.clone();
    after["demo"] = json!(true);
    let proposal = fixture.propose_config_later(&base, after, "op-l06");
    let draining = wait_for(Duration::from_secs(20), Duration::from_millis(5), || {
        drains(3).then_some(())
    });
    assert!(draining.is_some(), "hostd never reached the hand-over");
    signal(pid, libc::SIGKILL);

    let answer = proposal.join().unwrap();
    let record = &answer["result"];
    let state = record["state"].as_str().unwrap_or_default();
    assert!(
        ["rolled_back", "partially_applied"].contains(&state),
        "expected a failure or a partial completion: {answer}"
    );
    let items = items_of(record);
    eprintln!(
        "L-06 measured: the change ended {state} with {} items listed",
        items.len()
    );
    assert!(!items.is_empty(), "no items listed: {record}");
    for item in &items {
        assert!(
            item["participant"].is_string()
                && item["key"].is_string()
                && item["status"].is_string(),
            "an item without participant, key and status: {item}"
        );
    }
    assert!(
        items.iter().any(|item| item["participant"] == "hostd"
            && item["status"] == "failed"
            && item["reason"] == "participant.disconnected"),
        "the lost hand-over is not listed: {record}"
    );

    fixture.wait_available(TASKS_LIST, Duration::from_secs(30));
    let (_, now) = fixture.host();
    assert!(
        now > Some(generation),
        "generation {now:?} after {generation}"
    );
    // Give a replay every chance to happen before looking.
    thread::sleep(Duration::from_secs(2));
    assert_eq!(
        file_identity(&todo),
        identity,
        "todo.txt was written again after the restart"
    );
    let content = std::fs::read_to_string(&todo).unwrap();
    assert_eq!(content.matches(marker).count(), 1, "{content}");
    let listed = fixture.cli.result(TASKS_LIST, json!({}));
    assert_eq!(listed.to_string().matches(marker).count(), 1, "{listed}");
    let (head, _) = fixture.profile();
    assert_eq!(head, base, "a failed change moved the head");
    assert_eq!(fixture.tasks_entry().1, config_before);

    // Negative: the new hostd did not know the change; the readback decided.
    let change_id = record["change_id"].as_str().unwrap();
    assert!(
        fixture
            .log_lines()
            .iter()
            .any(|line| line["event"] == "participant.change_unknown"
                && line["change_id"] == change_id
                && line["role"] == "hostd"),
        "the restarted hostd was never asked about {change_id}"
    );
    let operations = record["operations"].as_array().unwrap();
    let commit = operations
        .iter()
        .find(|operation| operation["participant"] == "hostd" && operation["step"] == "commit")
        .expect("a hostd commit operation");
    assert!(
        operations
            .iter()
            .any(|operation| operation["participant"] == "hostd"
                && operation["step"] == "readback"
                && operation["state"] == "succeeded"
                && operation["seq"].as_u64() > commit["seq"].as_u64()),
        "no successful readback after the lost commit: {record}"
    );
}

// ---- L-07 ----------------------------------------------------------------------------

/// Lease ids Core logged for `generation` (event `host.lease_registered`).
fn leases_of_generation(fixture: &Fixture, generation: u64) -> Vec<String> {
    fixture
        .log_lines()
        .into_iter()
        .filter(|line| {
            line["event"] == "host.lease_registered"
                && line["generation"] == generation.to_string().as_str()
        })
        .filter_map(|line| line["lease_id"].as_str().map(String::from))
        .collect()
}

/// L-07 租約逾期. Positive: hostd stops renewing (SIGSTOP for 10 s) → Core
/// revokes its bindings and later calls are refused; once it is continued,
/// the service is registered again under a new generation. (hostd's
/// heartbeat lapses before its leases would: after 6 s Core treats it as
/// gone, SIGTERM/SIGKILLs it and supervision starts the next generation —
/// host protocol §3.) Negative: the old generation's lease ids, presented to
/// Core after the recovery, are refused (`expired`), never renewed.
#[test]
fn l07_stopped_renewal_revokes_bindings_and_old_leases_stay_dead() {
    let fixture = Fixture::start(
        "l07",
        Setup {
            host_fault: Some("lease.renew:present={work}/stale-leases".into()),
            ..Setup::default()
        },
    );
    fixture.wait_available(TASKS_LIST, Duration::from_secs(30));
    let (Some(pid), Some(generation)) = fixture.host() else {
        panic!("hostd is not running");
    };
    let old = leases_of_generation(&fixture, generation);
    assert!(
        old.len() >= 4,
        "generation {generation} registered {old:?}; the tasks service registers four"
    );
    let leases_before = fixture.leases();

    let stopped = Instant::now();
    signal(pid, libc::SIGSTOP);
    let revoked = wait_for(Duration::from_secs(10), Duration::from_millis(20), || {
        let (available, reason) = fixture.availability(TASKS_LIST);
        (!available).then(|| (stopped.elapsed(), reason))
    });
    let (after, reason) = revoked.expect("Core kept the binding of a stopped hostd");
    eprintln!(
        "L-07 measured: binding revoked {} ms after SIGSTOP ({reason:?})",
        after.as_millis()
    );
    assert_eq!(fixture.leases(), 0, "leases survived the revocation");
    let refused = fixture.cli.call(TASKS_LIST, json!({}), None);
    assert_eq!(refused["error"]["name"], "unavailable", "{refused}");

    // Hold the stop for the table's 10 s, then continue it.
    if let Some(rest) = Duration::from_secs(10).checked_sub(stopped.elapsed()) {
        thread::sleep(rest);
    }
    signal(pid, libc::SIGCONT);
    fixture.wait_available(TASKS_LIST, Duration::from_secs(30));
    let (Some(new_pid), Some(new_generation)) = fixture.host() else {
        panic!("hostd did not come back");
    };
    assert!(
        new_generation > generation,
        "generation {new_generation} after {generation}"
    );
    assert_ne!(new_pid, pid);
    assert!(
        !running(pid),
        "the stopped hostd {pid} is still running next to {new_pid}"
    );
    let new = leases_of_generation(&fixture, new_generation);
    assert!(
        !new.is_empty(),
        "generation {new_generation} registered nothing"
    );
    assert!(
        new.iter().all(|lease| !old.contains(lease)),
        "a lease id was reused: {new:?} / {old:?}"
    );
    let served = fixture.cli.call(TASKS_LIST, json!({}), None);
    assert!(served.get("result").is_some(), "{served}");

    // Negative: present the old generation's ids on the new connection.
    std::fs::write(fixture.path("stale-leases"), old.join("\n")).unwrap();
    let verdict = wait_for(Duration::from_secs(15), Duration::from_millis(50), || {
        fixture
            .log_lines()
            .into_iter()
            .find(|line| line["msg"] == "foreign lease ids presented")
    })
    .expect("hostd never presented the old lease ids");
    eprintln!("L-07 measured: old leases presented → {verdict}");
    let strings = |value: &Value| -> Vec<String> {
        value
            .as_array()
            .map(|items| {
                items
                    .iter()
                    .filter_map(|item| item.as_str().map(String::from))
                    .collect()
            })
            .unwrap_or_default()
    };
    let presented = strings(&verdict["presented"]);
    let expired = strings(&verdict["expired"]);
    assert_eq!(presented.len(), old.len(), "{verdict}");
    assert_eq!(
        verdict["renewed"],
        json!([]),
        "an old lease was renewed: {verdict}"
    );
    for lease in &old {
        assert!(
            expired.contains(lease),
            "{lease} was not refused: {verdict}"
        );
    }
    // The refusal touched nothing that is live.
    let served = fixture.cli.call(TASKS_LIST, json!({}), None);
    assert!(served.get("result").is_some(), "{served}");
    assert_eq!(fixture.leases(), leases_before);
}

// ---- L-09 ----------------------------------------------------------------------------

/// The JSON lines an Agent stand-in wrote to its `--out` file.
fn standin_lines(fixture: &Fixture, name: &str) -> Vec<Value> {
    std::fs::read_to_string(fixture.path(name))
        .unwrap_or_default()
        .lines()
        .filter_map(|line| serde_json::from_str(line).ok())
        .collect()
}

/// Open a stand-in's gate and wait for its answer (a line with an `id`).
fn run_standin(fixture: &Fixture, gate: &str, out: &str) -> Value {
    std::fs::write(fixture.path(gate), b"go").unwrap();
    wait_for(Duration::from_secs(25), Duration::from_millis(20), || {
        standin_lines(fixture, out)
            .into_iter()
            .find(|line| line.get("id").is_some())
    })
    .unwrap_or_else(|| panic!("the stand-in behind {gate} never answered"))
}

/// The `base_revision_stale` reason of a preflight rejection. (A stale plan
/// usually also carries `stale_intent`: its `before` no longer matches.)
fn stale_base(answer: &Value) -> Value {
    assert_eq!(answer["error"]["name"], "preflight_rejected", "{answer}");
    answer["error"]["data"]["reasons"]
        .as_array()
        .and_then(|reasons| {
            reasons
                .iter()
                .find(|reason| reason["code"] == "base_revision_stale")
                .cloned()
        })
        .unwrap_or_else(|| panic!("not rejected for a stale base: {answer}"))
}

/// L-09 prepare 期間手動修改同一項配置 (AT-10: the user changes the item while
/// the Agent prepares its change). Positive: the Agent stand-in's ChangeSet,
/// planned on the old head, is rejected with `base_revision_stale` when Core
/// checks it; the user's change is what stays. Negative: two ChangeSets that
/// reach the coordinator at the same moment are strictly serialized — the
/// second is not even drafted while the first is held in `prepared`, and it
/// sees the first one's head.
#[test]
fn l09_a_stale_plan_is_rejected_and_the_manual_edit_stays() {
    let fixture = Fixture::start(
        "l09",
        Setup {
            standins: vec![
                "--gate {work}/go-agent --out {work}/agent.out propose {work}/agent.json op-l09-agent"
                    .into(),
            ],
            ..Setup::default()
        },
    );
    fixture.wait_available(TASKS_LIST, Duration::from_secs(30));
    // The Agent reads the head and plans its change on it.
    let (planned_on, _) = fixture.profile();
    let (entry, before) = fixture.tasks_entry();
    std::fs::write(
        fixture.path("agent.json"),
        json!({"base_revision": planned_on, "ops": [{"op": "set_entry_config", "entry_id": entry, "before": before, "after": {"demo": false}}]})
            .to_string(),
    )
    .unwrap();
    // Meanwhile the user changes the same item by hand.
    let manual = fixture.propose_config(&planned_on, json!({"demo": true}), Some("op-l09-manual"));
    assert_eq!(manual["result"]["state"], "committed", "{manual}");
    let manual_head = manual["result"]["committed_revision"]
        .as_str()
        .unwrap()
        .to_string();

    let answer = run_standin(&fixture, "go-agent", "agent.out");
    let reason = stale_base(&answer);
    assert_eq!(
        reason["detail"]["head_revision"],
        manual_head.as_str(),
        "{answer}"
    );
    let stored = fixture.change("op-l09-agent");
    assert_eq!(stored["result"]["state"], "rejected", "{stored}");
    assert_eq!(
        stored["result"]["origin"]["kind"], "agent_standin",
        "{stored}"
    );
    let (head, _) = fixture.profile();
    assert_eq!(head, manual_head, "the stale plan moved the head");
    assert_eq!(fixture.tasks_entry().1, json!({"demo": true}));
}

#[test]
fn l09_negative_two_changes_at_once_are_strictly_serialized() {
    let fixture = Fixture::start(
        "l09n",
        Setup {
            core_fault: Some(hold(1)),
            ..Setup::default()
        },
    );
    fixture.wait_available(TASKS_LIST, Duration::from_secs(30));
    let (base, _) = fixture.profile();
    let start = Arc::new(std::sync::Barrier::new(2));
    let send = |operation: &'static str, demo: bool| {
        let (entry, before) = fixture.tasks_entry();
        let cli = Arc::clone(&fixture.cli);
        let start = Arc::clone(&start);
        let body = json!({"base_revision": base, "ops": [{"op": "set_entry_config", "entry_id": entry, "before": before, "after": {"demo": demo}}]});
        thread::spawn(move || {
            start.wait();
            cli.call("desktop.changes.propose", body, Some(operation))
        })
    };
    let a = send("op-l09-a", true);
    let b = send("op-l09-b", false);
    fixture.wait_held();
    // While one change is held in `prepared`, the other has no record at all.
    let (held_a, held_b) = (fixture.change("op-l09-a"), fixture.change("op-l09-b"));
    let held: Vec<&Value> = [&held_a, &held_b]
        .into_iter()
        .filter(|answer| answer.get("result").is_some())
        .collect();
    assert_eq!(
        held.len(),
        1,
        "both changes were in the coordinator: {held_a} {held_b}"
    );
    assert_eq!(held[0]["result"]["state"], "prepared");
    let waiting = if held_a.get("result").is_some() {
        &held_b
    } else {
        &held_a
    };
    assert_eq!(waiting["error"]["name"], "not_found", "{waiting}");

    fixture.release();
    let (a, b) = (a.join().unwrap(), b.join().unwrap());
    let (first, second) = if a.get("result").is_some() {
        (a, b)
    } else {
        (b, a)
    };
    assert_eq!(first["result"]["state"], "committed", "{first}");
    let first_head = first["result"]["committed_revision"].as_str().unwrap();
    assert_eq!(
        stale_base(&second)["detail"]["head_revision"],
        first_head,
        "the second did not see the first's head: {second}"
    );
    // The second was drafted only after the first had finished.
    let second_id = second["error"]["data"]["change_id"].as_str().unwrap();
    let second_record = fixture
        .cli
        .result("desktop.changes.get", json!({"change_id": second_id}));
    assert!(
        second_record["created_at"].as_str() >= first["result"]["updated_at"].as_str(),
        "the changes overlapped: {first} / {second_record}"
    );
    let (head, _) = fixture.profile();
    assert_eq!(head, first_head);
    assert_eq!(
        fixture.tasks_entry().1,
        first["result"]["ops"][0]["after"],
        "the head does not hold the first change"
    );
}

// ---- L-10 ----------------------------------------------------------------------------

fn standin_pid(fixture: &Fixture, needle: &str) -> u32 {
    children(fixture.core.id())
        .into_iter()
        .find(|pid| {
            let line = command_line(*pid);
            line.contains("standin.mjs") && line.contains(needle)
        })
        .unwrap_or_else(|| panic!("no stand-in with {needle} under Core"))
}

/// L-10 客戶端程序終止（受理前／後）, with the Agent stand-in. Positive: a
/// stand-in killed after sending `changes.propose` but before the coordinator
/// accepted it → nothing runs; one killed after acceptance → Core finishes
/// the change; a new stand-in finds the real outcome by `operation_id`.
/// Negative: resending with the same `idempotency_key` after acceptance
/// returns the existing `change_id` and makes no second change.
#[test]
fn l10_a_client_killed_before_or_after_acceptance() {
    let fixture = Fixture::start(
        "l10",
        Setup {
            core_fault: Some(hold(2)),
            standins: vec![
                "--gate {work}/go-1 --out {work}/s1.out propose {work}/before.json op-l10-before"
                    .into(),
                "--gate {work}/go-2 --out {work}/s2.out propose {work}/after.json op-l10-after"
                    .into(),
                "--gate {work}/go-3 --out {work}/s3.out get op-l10-after".into(),
                "--gate {work}/go-4 --out {work}/s4.out get op-l10-before".into(),
                "--gate {work}/go-5 --out {work}/s5.out propose {work}/after.json op-l10-resend"
                    .into(),
            ],
            ..Setup::default()
        },
    );
    fixture.wait_available(TASKS_LIST, Duration::from_secs(30));
    for out in ["s1.out", "s2.out", "s3.out", "s4.out", "s5.out"] {
        assert!(
            wait_for(Duration::from_secs(20), Duration::from_millis(20), || {
                (!standin_lines(&fixture, out).is_empty()).then_some(())
            })
            .is_some(),
            "the stand-in writing {out} did not connect"
        );
    }
    let (entry, before) = fixture.tasks_entry();
    let (head0, _) = fixture.profile();

    // ① Before acceptance. Another change holds the coordinator in
    // `prepared`, so the stand-in's proposal can only wait in the queue.
    let busy = fixture.propose_config_later(&head0, json!({"demo": true}), "op-l10-busy");
    fixture.wait_held();
    std::fs::write(
        fixture.path("before.json"),
        json!({"base_revision": head0, "ops": [{"op": "set_entry_config", "entry_id": entry, "before": before, "after": {"demo": false}}]})
            .to_string(),
    )
    .unwrap();
    let s1 = standin_pid(&fixture, "op-l10-before");
    std::fs::write(fixture.path("go-1"), b"go").unwrap();
    assert!(
        wait_for(Duration::from_secs(10), Duration::from_millis(5), || {
            standin_lines(&fixture, "s1.out")
                .iter()
                .any(|line| line["sent"] == "desktop.changes.propose")
                .then_some(())
        })
        .is_some(),
        "stand-in 1 never sent its proposal"
    );
    // Let Core read the request and queue it, then kill the sender.
    thread::sleep(Duration::from_millis(300));
    assert!(
        !standin_lines(&fixture, "s1.out")
            .iter()
            .any(|line| line.get("id").is_some()),
        "the proposal was answered while the coordinator was held"
    );
    signal(s1, libc::SIGKILL);
    thread::sleep(Duration::from_millis(300));
    fixture.release();
    let busy = busy.join().unwrap();
    assert_eq!(busy["result"]["state"], "committed", "{busy}");
    let head1 = busy["result"]["committed_revision"]
        .as_str()
        .unwrap()
        .to_string();
    // Nothing ran for the killed stand-in: no record under its operation id.
    let dropped = wait_for(Duration::from_secs(10), Duration::from_millis(20), || {
        fixture.log_lines().into_iter().find(|line| {
            line["event"] == "change.dropped_before_acceptance"
                && line["operation_id"] == "op-l10-before"
        })
    });
    assert!(dropped.is_some(), "Core did not drop the orphaned proposal");
    let lookup = run_standin(&fixture, "go-4", "s4.out");
    assert_eq!(lookup["error"]["name"], "not_found", "{lookup}");
    let listed = fixture.cli.result("desktop.changes.list", json!({}));
    let count = listed["changes"].as_array().unwrap().len();

    // ② After acceptance: the change is drafted and prepared, then its
    // sender dies; Core completes it.
    let (entry, before) = fixture.tasks_entry();
    std::fs::write(
        fixture.path("after.json"),
        json!({"base_revision": head1, "idempotency_key": "l10-after", "ops": [{"op": "set_entry_config", "entry_id": entry, "before": before, "after": {"demo": false}}]})
            .to_string(),
    )
    .unwrap();
    let s2 = standin_pid(&fixture, "op-l10-after");
    std::fs::write(fixture.path("go-2"), b"go").unwrap();
    fixture.wait_held();
    let accepted = fixture.change("op-l10-after");
    assert_eq!(accepted["result"]["state"], "prepared", "{accepted}");
    let change_id = accepted["result"]["change_id"]
        .as_str()
        .unwrap()
        .to_string();
    signal(s2, libc::SIGKILL);
    thread::sleep(Duration::from_millis(300));
    fixture.release();
    let finished = wait_for(Duration::from_secs(20), Duration::from_millis(50), || {
        let record = fixture.change("op-l10-after");
        let state = record["result"]["state"].as_str()?.to_string();
        ["committed", "rolled_back", "partially_applied", "aborted"]
            .contains(&state.as_str())
            .then_some(record)
    })
    .expect("Core did not finish the accepted change");
    assert_eq!(finished["result"]["state"], "committed", "{finished}");
    let (head2, _) = fixture.profile();
    assert_eq!(finished["result"]["committed_revision"], head2.as_str());
    // A new stand-in finds the real outcome by operation id.
    let found = run_standin(&fixture, "go-3", "s3.out");
    assert_eq!(found["result"]["change_id"], change_id.as_str(), "{found}");
    assert_eq!(found["result"]["state"], "committed", "{found}");
    assert_eq!(
        found["result"]["origin"]["kind"], "agent_standin",
        "{found}"
    );

    // Negative: the same idempotency key again.
    let resent = run_standin(&fixture, "go-5", "s5.out");
    assert_eq!(
        resent["result"]["change_id"],
        change_id.as_str(),
        "{resent}"
    );
    let listed = fixture.cli.result("desktop.changes.list", json!({}));
    let changes = listed["changes"].as_array().unwrap();
    assert_eq!(
        changes.len(),
        count + 1,
        "a second change was made: {listed}"
    );
    let (head, _) = fixture.profile();
    assert_eq!(head, head2, "the resend moved the head");
}
