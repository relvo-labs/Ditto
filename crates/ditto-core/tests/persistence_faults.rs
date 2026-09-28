//! EX1-09 against the real binary: Core is killed (SIGKILL from a fault
//! point) in `prepared`, `applying` and `verifying`, started again, and every
//! change must end in a terminal state decided by readback; storage faults
//! (SQLITE_FULL, SQLITE_IOERR, a failed unpack) must leave the head, the
//! last-known-good and the package store as they were.
//!
//! Needs the `fault-injection` build:
//! `cargo test -p ditto-core --features fault-injection --test persistence_faults`.
#![cfg(feature = "fault-injection")]

use std::{
    collections::HashMap,
    io::{BufRead, BufReader, Write},
    os::unix::net::UnixStream,
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    sync::{mpsc, Arc, Mutex},
    thread,
    time::{Duration, Instant},
};

use serde_json::{json, Value};

const TOKEN: &str = "persistence-fault-token";
const PROTOCOL: &str = ditto_protocol::PROTOCOL_VERSION;

struct Dirs {
    root: PathBuf,
}

impl Dirs {
    fn new(label: &str) -> Self {
        let root = std::env::temp_dir().join(format!(
            "ditto-faults-{label}-{}-{}",
            std::process::id(),
            ditto_protocol::ids::ulid()
        ));
        std::fs::create_dir_all(root.join("run")).unwrap();
        Self { root }
    }

    fn socket(&self) -> PathBuf {
        self.root.join("run/core.sock")
    }
}

impl Drop for Dirs {
    fn drop(&mut self) {
        let _ = Command::new("chmod")
            .arg("-R")
            .arg("u+w")
            .arg(&self.root)
            .status();
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

/// A Core that is killed when the test lets go of it, so a failing assertion
/// never leaves a Core running on its own.
struct CoreProcess(Child);

impl Drop for CoreProcess {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

impl std::ops::Deref for CoreProcess {
    type Target = Child;
    fn deref(&self) -> &Child {
        &self.0
    }
}

impl std::ops::DerefMut for CoreProcess {
    fn deref_mut(&mut self) -> &mut Child {
        &mut self.0
    }
}

fn start_core(dirs: &Dirs, fault: Option<&str>) -> CoreProcess {
    let _ = std::fs::remove_file(dirs.socket());
    let mut command = Command::new(env!("CARGO_BIN_EXE_ditto-core"));
    command
        .args(["serve", "--development", "--compositor", "fixture"])
        .env("DITTO_DATA_DIR", dirs.root.join("store"))
        .env("DITTO_RUNTIME_DIR", dirs.root.join("run"))
        .env("DITTO_SYSTEM", "none")
        .env("DITTO_DEV_TOKEN", TOKEN)
        .env_remove("WAYFIRE_SOCKET")
        .env_remove("SWAYSOCK")
        .env_remove("DITTO_FAULT")
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    if let Some(fault) = fault {
        command.env("DITTO_FAULT", fault);
    }
    let child = CoreProcess(command.spawn().expect("ditto-core starts"));
    let deadline = Instant::now() + Duration::from_secs(10);
    while !dirs.socket().exists() {
        assert!(Instant::now() < deadline, "core socket did not appear");
        thread::sleep(Duration::from_millis(20));
    }
    child
}

type Handler = Arc<dyn Fn(&str, &Value) -> Value + Send + Sync>;

struct Peer {
    writer: Arc<Mutex<UnixStream>>,
    pending: Arc<Mutex<HashMap<String, mpsc::Sender<Value>>>>,
    next: Mutex<u64>,
}

impl Peer {
    fn connect(socket: &Path, kind: &str, handler: Option<Handler>) -> Arc<Self> {
        let deadline = Instant::now() + Duration::from_secs(10);
        let stream = loop {
            match UnixStream::connect(socket) {
                Ok(stream) => break stream,
                Err(error) => {
                    assert!(Instant::now() < deadline, "connect: {error}");
                    thread::sleep(Duration::from_millis(20));
                }
            }
        };
        let writer = Arc::new(Mutex::new(stream.try_clone().unwrap()));
        let pending: Arc<Mutex<HashMap<String, mpsc::Sender<Value>>>> = Arc::default();
        {
            let (writer, pending) = (Arc::clone(&writer), Arc::clone(&pending));
            thread::spawn(move || {
                let mut reader = BufReader::new(stream);
                let mut line = String::new();
                while reader.read_line(&mut line).unwrap_or(0) > 0 {
                    let message: Value = serde_json::from_str(&line).unwrap_or(Value::Null);
                    line.clear();
                    if let (Some(method), Some(id)) =
                        (message["method"].as_str(), message["id"].as_str())
                    {
                        if let Some(handler) = &handler {
                            let reply = json!({"jsonrpc": "2.0", "id": id, "result": handler(method, &message["params"])});
                            let mut stream = writer.lock().unwrap();
                            let _ = writeln!(stream, "{reply}");
                        }
                        continue;
                    }
                    if let Some(id) = message["id"].as_str() {
                        if let Some(waiter) = pending.lock().unwrap().remove(id) {
                            let _ = waiter.send(message);
                        }
                    }
                }
            });
        }
        let peer = Arc::new(Self {
            writer,
            pending,
            next: Mutex::new(0),
        });
        let hello = peer.raw(
            "core.handshake",
            json!({"protocol_version": PROTOCOL, "client": {"kind": kind, "version": "0.2.0"}, "auth": {"token": TOKEN}}),
            Duration::from_secs(10),
        );
        assert!(hello.get("result").is_some(), "handshake: {hello}");
        peer
    }

    fn raw(&self, method: &str, params: Value, timeout: Duration) -> Value {
        let id = {
            let mut next = self.next.lock().unwrap();
            *next += 1;
            format!("f-{next}")
        };
        let (waiter, answer) = mpsc::channel();
        self.pending.lock().unwrap().insert(id.clone(), waiter);
        {
            let mut stream = self.writer.lock().unwrap();
            let _ = writeln!(
                stream,
                "{}",
                json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params})
            );
        }
        answer.recv_timeout(timeout).unwrap_or(Value::Null)
    }

    fn call(&self, method: &str, mut params: Value, operation_id: Option<&str>) -> Value {
        params["_meta"] = json!({"protocol_version": PROTOCOL, "deadline_ms": 20000, "operation_id": operation_id});
        self.raw(method, params, Duration::from_secs(25))
    }
}

/// A Shell that outlives Core: its mounted state is kept across connections,
/// the way the real Shell keeps running when Core crashes.
/// The fake Shell's memory, kept across Core restarts: the committed
/// projection, and each change's candidate with the projection it replaced.
type ShellMemory = Arc<Mutex<(Option<Value>, HashMap<String, (Value, Option<Value>)>)>>;

fn shell_handler(state: ShellMemory) -> Handler {
    Arc::new(move |method, params| {
        let mut state = state.lock().unwrap();
        let change_id = params["change_id"].as_str().unwrap_or_default().to_string();
        let observed = |projection: &Option<Value>| match projection {
            Some(target) => {
                json!({"role": "shell", "mounts": target["slots"].as_array().unwrap().iter().map(|slot| json!({"slot": slot["slot"], "entry_id": slot["entry_id"], "mounted": true, "visible": true})).collect::<Vec<_>>(), "appearance": target["appearance"], "avatar": target["avatar"]})
            }
            None => json!({"role": "shell", "mounts": [], "appearance": null, "avatar": null}),
        };
        match method {
            "participant.prepare" => {
                let previous = state.0.clone();
                state
                    .1
                    .insert(change_id, (params["target"].clone(), previous));
                json!({"items": []})
            }
            "participant.commit" => {
                if let Some((target, _)) = state.1.get(&change_id).cloned() {
                    state.0 = Some(target);
                }
                json!({"items": []})
            }
            "participant.rollback" => {
                if let Some((_, previous)) = state.1.get(&change_id).cloned() {
                    state.0 = previous;
                }
                json!({"items": []})
            }
            "participant.abort" => json!({}),
            _ => json!({"change": null, "observed": observed(&state.0)}),
        }
    })
}

fn wait_exit(child: &mut Child) -> bool {
    let deadline = Instant::now() + Duration::from_secs(20);
    while Instant::now() < deadline {
        if child.try_wait().unwrap().is_some() {
            return true;
        }
        thread::sleep(Duration::from_millis(20));
    }
    let _ = child.kill();
    false
}

fn head(cli: &Peer) -> (String, String, Option<String>) {
    let got = cli.call("desktop.profiles.get", json!({}), None);
    (
        got["result"]["profile"]["head_revision"]
            .as_str()
            .unwrap()
            .to_string(),
        got["result"]["revision"]["document_sha256"]
            .as_str()
            .unwrap()
            .to_string(),
        got["result"]["profile"]["last_known_good"]
            .as_str()
            .map(String::from),
    )
}

fn wait_ready(cli: &Peer) {
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let answer = cli.call("desktop.profiles.get", json!({}), None);
        if answer["result"]["profile"]["head_revision"].is_string() {
            return;
        }
        assert!(
            Instant::now() < deadline,
            "Core did not finish startup recovery: {answer}"
        );
        thread::sleep(Duration::from_millis(20));
    }
}

#[test]
fn a_crash_in_each_state_ends_in_a_decided_outcome() {
    for (state, expected) in [
        ("prepared", "aborted"),
        ("applying", "rolled_back"),
        ("verifying", "committed"),
    ] {
        let dirs = Dirs::new(state);
        let shell_state = Arc::new(Mutex::new((None, HashMap::new())));
        let mut core = start_core(
            &dirs,
            Some(&format!("coordinator.after_state={state}:abort_process:1")),
        );
        let _shell = Peer::connect(
            &dirs.socket(),
            "quickshell",
            Some(shell_handler(Arc::clone(&shell_state))),
        );
        let cli = Peer::connect(&dirs.socket(), "dittoctl", None);
        // Let the boot sync reach the Shell first.
        thread::sleep(Duration::from_millis(300));
        let (base, _, _) = head(&cli);
        let operation = format!("op-fault-{state}");
        let _ = cli.call(
            "desktop.changes.propose",
            json!({"base_revision": base, "ops": [{"op": "set_value", "path": "/appearance/tokens/accent", "after": "#123456"}]}),
            Some(&operation),
        );
        assert!(
            wait_exit(&mut core),
            "{state}: the fault point did not end Core"
        );
        // Second life: same store, the Shell reconnects with what it has.
        let _core = start_core(&dirs, None);
        let _shell = Peer::connect(
            &dirs.socket(),
            "quickshell",
            Some(shell_handler(Arc::clone(&shell_state))),
        );
        let cli = Peer::connect(&dirs.socket(), "dittoctl", None);
        // Reads are served during recovery and show the change as it is;
        // wait for recovery to decide it.
        let deadline = Instant::now() + Duration::from_secs(20);
        let found = loop {
            let found = cli.call(
                "desktop.changes.get",
                json!({"operation_id": operation}),
                None,
            );
            if found["result"]["recovered_at"].is_string() || Instant::now() > deadline {
                break found;
            }
            thread::sleep(Duration::from_millis(50));
        };
        let record = &found["result"];
        assert_eq!(record["state"], expected, "{state}: {found}");
        assert!(
            record["recovered_at"].is_string(),
            "{state}: recovery did not mark it"
        );
        let listed = cli.call("desktop.changes.list", json!({}), None);
        for change in listed["result"]["changes"].as_array().unwrap() {
            let state_text = change["state"].as_str().unwrap();
            assert!(
                ![
                    "draft",
                    "validated",
                    "prepared",
                    "applying",
                    "verifying",
                    "rolling_back"
                ]
                .contains(&state_text),
                "a change was left in {state_text}"
            );
        }
    }
}

#[test]
fn a_full_disk_or_an_io_error_at_commit_leaves_the_head_and_last_good() {
    for (fault, key) in [
        ("store.commit_revision:full", "change.storage_full"),
        ("store.commit_revision:ioerr", "change.storage_error"),
    ] {
        let dirs = Dirs::new("storage");
        let shell_state = Arc::new(Mutex::new((None, HashMap::new())));
        let _core = start_core(&dirs, Some(fault));
        let _shell = Peer::connect(
            &dirs.socket(),
            "quickshell",
            Some(shell_handler(Arc::clone(&shell_state))),
        );
        let cli = Peer::connect(&dirs.socket(), "dittoctl", None);
        thread::sleep(Duration::from_millis(300));
        let (base, digest, good) = head(&cli);
        let answer = cli.call(
            "desktop.changes.propose",
            json!({"base_revision": base, "ops": [{"op": "set_value", "path": "/appearance/tokens/accent", "after": "#654321"}]}),
            None,
        );
        assert_eq!(
            answer["result"]["state"], "rolled_back",
            "{fault}: {answer}"
        );
        assert_eq!(answer["result"]["failure_key"], key, "{fault}");
        let (after, after_digest, after_good) = head(&cli);
        assert_eq!(
            (after, after_digest, after_good),
            (base, digest, good),
            "{fault}: the head moved"
        );
        // The Shell was put back on the base content.
        let shown = shell_state.lock().unwrap().0.clone().unwrap();
        assert_eq!(
            shown["appearance"]["tokens"]["accent"], "#b9a4ff",
            "{fault}"
        );
    }
}

#[test]
fn a_failed_unpack_leaves_no_half_package() {
    let dirs = Dirs::new("unpack");
    // A valid package: the failure is injected mid-unpack.
    let source = dirs.root.join("pkg-src");
    std::fs::create_dir_all(source.join("qml")).unwrap();
    std::fs::write(
        source.join("manifest.json"),
        json!({"manifest_version": 1, "id": "ditto.test.unpack", "version": "1.0.0", "name": "t", "author": "a", "license": "UNLICENSED",
               "source": "builtin", "plugin_kind": "qml_provider", "host_kind": "qml", "trust_level": "trusted",
               "required_protocol_version": "^0.2", "slots": ["ui.dock"], "qml_entry": "qml/P.qml", "hot_swap": "instant",
               "health": {"timeout_ms": 2000}, "cleanup": {"timeout_ms": 2000}, "idle_policy": "resident"})
        .to_string(),
    )
    .unwrap();
    std::fs::write(source.join("qml/P.qml"), "// test\n").unwrap();
    let archive = dirs.root.join("unpack.dittopkg");
    assert!(Command::new("tar")
        .arg("--zstd")
        .arg("-cf")
        .arg(&archive)
        .arg("-C")
        .arg(&source)
        .arg(".")
        .status()
        .unwrap()
        .success());
    let _core = start_core(&dirs, Some("store.unpack:ioerr"));
    let cli = Peer::connect(&dirs.socket(), "dittoctl", None);
    wait_ready(&cli);
    let job = cli.call(
        "desktop.plugins.install",
        json!({"path": archive.display().to_string(), "idempotency_key": "unpack-1"}),
        None,
    );
    assert_eq!(job["result"]["state"], "failed", "{job}");
    let staging = dirs.root.join("store/data/packages/.staging");
    let leftovers = std::fs::read_dir(&staging)
        .map(|dir| dir.count())
        .unwrap_or(0);
    assert_eq!(leftovers, 0, "staging kept a half-unpacked package");
    let installed = std::fs::read_dir(dirs.root.join("store/data/packages/sha256"))
        .map(|dir| dir.count())
        .unwrap_or(0);
    assert_eq!(installed, 0, "the package store holds a half package");
    let listed = cli.call("desktop.plugins.list", json!({}), None);
    assert!(listed["result"]["packages"]
        .as_array()
        .unwrap()
        .iter()
        .all(|package| package["package_id"] != "ditto.test.unpack"));
    // Without the fault the same archive installs.
    let again = cli.call(
        "desktop.plugins.install",
        json!({"path": archive.display().to_string(), "idempotency_key": "unpack-2"}),
        None,
    );
    assert_eq!(again["result"]["state"], "succeeded", "{again}");
}
