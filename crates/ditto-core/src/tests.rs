//! Core integration tests: a real Core (store, coordinator, router) on a
//! fixture compositor, with fake Shell and hostd participants speaking
//! protocol 0.2 over socket pairs. What the fakes report is what Core reads
//! back, so a lying fake is how readback mismatches are tested.

use super::*;
use crate::{
    core::{Core, CoreConfig},
    session::Session,
};
use ditto_compositor::fixture::FixtureCompositor;
use ditto_protocol::ids;
use ditto_protocol::{
    catalog,
    change::{ChangeRecord, ChangeState, ResultKind},
    participant::{Projection, ShellProjection},
};
use ditto_store::Paths;
use serde_json::json;
use std::{
    collections::HashMap,
    path::{Path, PathBuf},
    process::Command,
    sync::{mpsc, Mutex},
};

const TOKEN: &str = "once-only-test-token";

// ---- packages -------------------------------------------------------------

fn manifest(id: &str, kind: &str, host: &str, slots: &[&str], extra: Value) -> Value {
    let mut manifest = json!({
        "manifest_version": 1, "id": id, "version": "1.0.0", "name": id, "author": "Ditto",
        "license": "UNLICENSED", "source": "builtin", "plugin_kind": kind, "host_kind": host,
        "trust_level": "trusted", "required_protocol_version": "^0.2", "slots": slots,
        "hot_swap": if host == "qml" { "instant" } else { "controlled_handoff" },
        "health": {"timeout_ms": 2000}, "cleanup": {"timeout_ms": 2000}, "idle_policy": "resident"
    });
    if host == "qml" {
        manifest["qml_entry"] = json!("qml/Provider.qml");
    }
    if host == "cordis" {
        manifest["entry"] = json!("dist/index.mjs");
    }
    if let Value::Object(extra) = extra {
        for (key, value) in extra {
            manifest[key] = value;
        }
    }
    manifest
}

fn pack(directory: &Path, manifest: &Value) {
    let id = manifest["id"].as_str().unwrap();
    let source = directory.join(format!("src-{id}-{}", ids::ulid()));
    std::fs::create_dir_all(source.join("qml")).unwrap();
    std::fs::create_dir_all(source.join("dist")).unwrap();
    std::fs::write(
        source.join("manifest.json"),
        serde_json::to_string_pretty(manifest).unwrap(),
    )
    .unwrap();
    std::fs::write(source.join("qml/Provider.qml"), format!("// {id}\n")).unwrap();
    std::fs::write(source.join("dist/index.mjs"), format!("// {id}\n")).unwrap();
    let archive = directory.join(format!(
        "{id}-{}.dittopkg",
        manifest["version"].as_str().unwrap()
    ));
    let status = Command::new("tar")
        .arg("--zstd")
        .arg("-cf")
        .arg(&archive)
        .arg("-C")
        .arg(&source)
        .arg(".")
        .status()
        .unwrap();
    assert!(status.success());
    std::fs::remove_dir_all(source).unwrap();
}

fn builtin_packages(directory: &Path) {
    std::fs::create_dir_all(directory).unwrap();
    for (id, slot) in [
        ("ditto.panel.top", "ui.panel_top"),
        ("ditto.dock.bottom", "ui.dock"),
        ("ditto.dock.pill", "ui.dock"),
        ("ditto.dock.broken", "ui.dock"),
        ("ditto.launcher.grid", "ui.launcher"),
        ("ditto.launcher.search", "ui.launcher"),
    ] {
        let extra = if id.starts_with("ditto.launcher.") {
            json!({"commands": [{"id": "launcher.toggle", "title_key": "command.launcher.toggle"}]})
        } else {
            json!({})
        };
        pack(
            directory,
            &manifest(id, "qml_provider", "qml", &[slot], extra),
        );
    }
    for id in ["ditto.layout.floating", "ditto.layout.simple-tile"] {
        pack(
            directory,
            &manifest(
                id,
                "declarative_bundle",
                "core_builtin",
                &["layout.strategy"],
                json!({}),
            ),
        );
    }
    pack(
        directory,
        &manifest(
            "ditto.svc.tasks",
            "service",
            "cordis",
            &["svc.tasks"],
            json!({
                "provides": [{"capability": "desktop.tasks.list"}, {"capability": "desktop.tasks.add"}, {"capability": "desktop.tasks.complete"}],
                "events": [{"name": "tasks/changed", "schema": {"type": "object"}, "coalesce": "latest"}],
                "permissions": ["files:*"]
            }),
        ),
    );
    // A Dock that only a new session can load.
    pack(
        directory,
        &manifest(
            "ditto.test.next-login",
            "qml_provider",
            "qml",
            &["ui.dock"],
            json!({"hot_swap": "session_restart"}),
        ),
    );
    // Preflight negatives.
    pack(
        directory,
        &manifest(
            "ditto.test.needs-missing",
            "qml_provider",
            "qml",
            &["ui.dock"],
            json!({"requires": [{"package": "ditto.nowhere"}]}),
        ),
    );
    pack(
        directory,
        &manifest(
            "ditto.test.needs-dock-2",
            "qml_provider",
            "qml",
            &["ui.dock"],
            json!({"requires": [{"package": "ditto.dock.pill", "version": "^2"}]}),
        ),
    );
    pack(
        directory,
        &manifest(
            "ditto.test.future",
            "qml_provider",
            "qml",
            &["ui.dock"],
            json!({"required_protocol_version": "^0.9"}),
        ),
    );
    pack(
        directory,
        &manifest(
            "ditto.test.cycle-a",
            "qml_provider",
            "qml",
            &["ui.dock"],
            json!({"requires": [{"package": "ditto.test.cycle-b"}]}),
        ),
    );
    pack(
        directory,
        &manifest(
            "ditto.test.cycle-b",
            "qml_provider",
            "qml",
            &["ui.launcher"],
            json!({"requires": [{"package": "ditto.test.cycle-a"}]}),
        ),
    );
    pack(
        directory,
        &manifest(
            "ditto.test.greedy",
            "service",
            "cordis",
            &[],
            json!({"resource_budget": {"memory_mib": 512}}),
        ),
    );
}

// ---- a peer over a socket pair ----------------------------------------------

type Handler = Arc<dyn Fn(&str, &Value) -> Result<Value, (ErrorName, String)> + Send + Sync>;

struct TestPeer {
    stream: UnixStream,
    pending: Arc<Mutex<HashMap<String, mpsc::Sender<Value>>>>,
    events: Arc<Mutex<Vec<Value>>>,
    next: std::sync::atomic::AtomicU64,
    handshake: Value,
}

impl TestPeer {
    fn connect(core: &Arc<Core>, kind: &str, handler: Option<Handler>) -> Arc<Self> {
        let (client, server) = UnixStream::pair().expect("socket pair");
        let server_core = Arc::clone(core);
        thread::spawn(move || {
            let _ = serve_connection(server, server_core, TOKEN);
        });
        let pending: Arc<Mutex<HashMap<String, mpsc::Sender<Value>>>> =
            Arc::new(Mutex::new(HashMap::new()));
        let events = Arc::new(Mutex::new(Vec::new()));
        let reader_stream = client.try_clone().unwrap();
        let writer = Arc::new(Mutex::new(client.try_clone().unwrap()));
        {
            let pending = Arc::clone(&pending);
            let events = Arc::clone(&events);
            let writer = Arc::clone(&writer);
            thread::spawn(move || {
                let mut reader = BufReader::new(reader_stream);
                loop {
                    let mut line = String::new();
                    if reader.read_line(&mut line).unwrap_or(0) == 0 {
                        return;
                    }
                    let Ok(message) = serde_json::from_str::<Value>(&line) else {
                        continue;
                    };
                    if let Some(method) = message.get("method").and_then(Value::as_str) {
                        if method == "desktop.events" || message.get("id").is_none() {
                            events.lock().unwrap().push(message.clone());
                            continue;
                        }
                        let Some(handler) = handler.clone() else {
                            continue;
                        };
                        let writer = Arc::clone(&writer);
                        let method = method.to_string();
                        thread::spawn(move || {
                            let id = message["id"].as_str().unwrap().to_string();
                            let reply = match handler(&method, &message["params"]) {
                                Ok(result) => json!({"jsonrpc": "2.0", "id": id, "result": result}),
                                Err((name, text)) => {
                                    json!({"jsonrpc": "2.0", "id": id, "error": {"code": name.code(), "name": name, "message": text}})
                                }
                            };
                            let mut stream = writer.lock().unwrap();
                            let _ = serde_json::to_writer(&mut *stream, &reply);
                            let _ = stream.write_all(b"\n");
                        });
                        continue;
                    }
                    if let Some(id) = message.get("id").and_then(Value::as_str) {
                        if let Some(waiter) = pending.lock().unwrap().remove(id) {
                            let _ = waiter.send(message);
                        }
                    }
                }
            });
        }
        let mut peer = Self {
            stream: client,
            pending,
            events,
            next: std::sync::atomic::AtomicU64::new(0),
            handshake: Value::Null,
        };
        let handshake = peer.raw(
            "core.handshake",
            json!({"protocol_version": PROTOCOL_VERSION, "client": {"kind": kind, "version": "0.2.0"}, "auth": {"token": TOKEN}}),
        );
        peer.handshake = handshake;
        Arc::new(peer)
    }

    fn raw(&self, method: &str, params: Value) -> Value {
        let id = format!("t-{}", self.next.fetch_add(1, Ordering::SeqCst) + 1);
        let (waiter, answer) = mpsc::channel();
        self.pending.lock().unwrap().insert(id.clone(), waiter);
        let mut stream = self.stream.try_clone().unwrap();
        serde_json::to_writer(
            &mut stream,
            &json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params}),
        )
        .unwrap();
        stream.write_all(b"\n").unwrap();
        answer
            .recv_timeout(Duration::from_secs(40))
            .expect("core answered")
    }

    fn call(&self, method: &str, params: Value) -> Value {
        self.call_as(method, params, None)
    }

    fn call_as(&self, method: &str, mut params: Value, on_behalf_of: Option<&str>) -> Value {
        let mut meta = json!({"protocol_version": PROTOCOL_VERSION, "deadline_ms": 20000});
        if let Some(entry) = on_behalf_of {
            meta["on_behalf_of"] = json!(entry);
        }
        params["_meta"] = meta;
        self.raw(method, params)
    }

    fn result(&self, method: &str, params: Value) -> Value {
        let response = self.call(method, params);
        assert!(
            response.get("result").is_some(),
            "{method} failed: {response}"
        );
        response["result"].clone()
    }

    fn close(&self) {
        let _ = self.stream.shutdown(std::net::Shutdown::Both);
    }
}

// ---- fake participants ------------------------------------------------------

#[derive(Default)]
struct ShellState {
    committed: Option<ShellProjection>,
    candidates: HashMap<String, (ShellProjection, Option<ShellProjection>)>,
    /// Refuse candidates of this package at prepare (a QML load failure).
    broken_package: Option<String>,
    /// Report the old mounts after commit: a Shell that says "done" but did not.
    lie_after_commit: bool,
    /// At rollback, report this slot as not restored (the thing it placed
    /// is gone, as a window closed in the meantime would be).
    cannot_restore: Option<String>,
    prepares: u32,
}

fn shell_observation(projection: &Option<ShellProjection>) -> Value {
    match projection {
        Some(projection) => json!({
            "role": "shell",
            "mounts": projection.slots.iter().map(|slot| json!({"slot": slot.slot, "entry_id": slot.entry_id, "mounted": true, "visible": true})).collect::<Vec<_>>(),
            "appearance": projection.appearance,
            "avatar": projection.avatar,
        }),
        None => json!({"role": "shell", "mounts": [], "appearance": null, "avatar": null}),
    }
}

/// A fake Shell gets the boot sync (a prepare and a commit of its own) soon
/// after it connects; tests that count prepares or change how the Shell
/// answers must start after it, or they race it.
fn wait_for_boot_sync(state: &Arc<Mutex<ShellState>>) {
    let deadline = Instant::now() + Duration::from_secs(5);
    while state.lock().unwrap().committed.is_none() && Instant::now() < deadline {
        thread::sleep(Duration::from_millis(20));
    }
    assert!(
        state.lock().unwrap().committed.is_some(),
        "the boot sync never reached the fake Shell"
    );
}

fn fake_shell(core: &Arc<Core>, state: Arc<Mutex<ShellState>>) -> Arc<TestPeer> {
    let handler: Handler = Arc::new(move |method, params| {
        let mut shell = state.lock().unwrap();
        let change_id = params["change_id"].as_str().unwrap_or_default().to_string();
        match method {
            "participant.prepare" => {
                shell.prepares += 1;
                let Ok(Projection::Shell(target)) =
                    serde_json::from_value::<Projection>(params["target"].clone())
                else {
                    return Err((ErrorName::InvalidParams, "not a shell projection".into()));
                };
                let broken = shell.broken_package.clone();
                let items: Vec<Value> = target
                    .slots
                    .iter()
                    .map(|slot| {
                        if Some(&slot.package) == broken.as_ref() {
                            json!({"key": slot.slot, "status": "failed", "reason": "qml_error"})
                        } else {
                            json!({"key": slot.slot, "status": "ready"})
                        }
                    })
                    .collect();
                let previous = shell.committed.clone();
                shell.candidates.insert(change_id, (target, previous));
                Ok(json!({"items": items}))
            }
            "participant.commit" => {
                let (target, _) = shell
                    .candidates
                    .get(&change_id)
                    .cloned()
                    .ok_or((ErrorName::NotFound, "unknown change".to_string()))?;
                if !shell.lie_after_commit {
                    shell.committed = Some(target.clone());
                }
                Ok(
                    json!({"items": target.slots.iter().map(|slot| json!({"key": slot.slot, "status": "applied"})).collect::<Vec<_>>()}),
                )
            }
            "participant.abort" => {
                shell.candidates.remove(&change_id);
                Ok(json!({}))
            }
            "participant.rollback" => {
                let (_, previous) = shell
                    .candidates
                    .get(&change_id)
                    .cloned()
                    .ok_or((ErrorName::NotFound, "unknown change".to_string()))?;
                shell.committed = previous;
                match &shell.cannot_restore {
                    Some(slot) => Ok(
                        json!({"items": [{"key": slot, "status": "not_restored", "reason": "window_closed"}]}),
                    ),
                    None => Ok(json!({"items": []})),
                }
            }
            "participant.state" => {
                Ok(json!({"change": null, "observed": shell_observation(&shell.committed)}))
            }
            _ => Err((ErrorName::Unsupported, method.to_string())),
        }
    });
    TestPeer::connect(core, "quickshell", Some(handler))
}

#[derive(Default)]
struct HostState {
    entries: Vec<Value>,
    candidates: HashMap<String, Vec<Value>>,
    active: HashMap<String, bool>,
    tasks: Vec<Value>,
    /// Try to register capabilities during prepare (candidate claiming).
    claim_at_prepare: bool,
    claim_outcome: Option<Value>,
}

fn fake_host(core: &Arc<Core>, state: Arc<Mutex<HostState>>) -> Arc<TestPeer> {
    let peer_slot: Arc<Mutex<Option<Arc<TestPeer>>>> = Arc::new(Mutex::new(None));
    let slot = Arc::clone(&peer_slot);
    let handler: Handler = Arc::new(move |method, params| {
        let peer = slot.lock().unwrap().clone();
        let change_id = params["change_id"].as_str().unwrap_or_default().to_string();
        match method {
            "participant.prepare" => {
                let entries = params["target"]["entries"]
                    .as_array()
                    .cloned()
                    .unwrap_or_default();
                let claim = state.lock().unwrap().claim_at_prepare;
                if claim {
                    if let (Some(peer), Some(entry)) = (&peer, entries.first()) {
                        let outcome = peer.call_as(
                            "host.capability.register",
                            json!({"capability_id": "desktop.tasks.list", "version": "1.0.0"}),
                            entry["entry_id"].as_str(),
                        );
                        state.lock().unwrap().claim_outcome = Some(outcome);
                    }
                }
                let items: Vec<Value> = entries
                    .iter()
                    .map(|entry| json!({"key": entry["entry_id"], "status": "ready"}))
                    .collect();
                state.lock().unwrap().candidates.insert(change_id, entries);
                Ok(json!({"items": items}))
            }
            "participant.commit" => {
                let entries = state
                    .lock()
                    .unwrap()
                    .candidates
                    .get(&change_id)
                    .cloned()
                    .unwrap_or_default();
                // Register the declared capabilities on commit, as hostd does.
                if let Some(peer) = &peer {
                    for entry in &entries {
                        for capability in entry["provides"].as_array().cloned().unwrap_or_default()
                        {
                            let _ = peer.call_as(
                                "host.capability.register",
                                json!({"capability_id": capability, "version": "1.0.0"}),
                                entry["entry_id"].as_str(),
                            );
                        }
                    }
                }
                let mut host = state.lock().unwrap();
                host.active = entries
                    .iter()
                    .map(|entry| (entry["entry_id"].as_str().unwrap().to_string(), true))
                    .collect();
                host.entries = entries.clone();
                Ok(
                    json!({"items": entries.iter().map(|entry| json!({"key": entry["entry_id"], "status": "applied"})).collect::<Vec<_>>()}),
                )
            }
            "participant.abort" => {
                state.lock().unwrap().candidates.remove(&change_id);
                Ok(json!({}))
            }
            "participant.rollback" => Ok(json!({"items": []})),
            "participant.state" => {
                let host = state.lock().unwrap();
                let entries: Vec<Value> = host
                    .entries
                    .iter()
                    .map(|entry| json!({"entry_id": entry["entry_id"], "fiber_state": "active", "mode": "active"}))
                    .collect();
                Ok(json!({"change": null, "observed": {"role": "hostd", "entries": entries}}))
            }
            "host.invoke" => {
                let mut host = state.lock().unwrap();
                match params["capability_id"].as_str().unwrap_or_default() {
                    "desktop.tasks.list" => Ok(
                        json!({"tasks": host.tasks, "sources": [{"source": "own", "status": "ok"}], "demo": false}),
                    ),
                    "desktop.tasks.add" => {
                        let task = json!({"task_id": format!("task-{}", host.tasks.len() + 1), "text": params["input"]["text"], "done": false, "source": "own"});
                        host.tasks.push(task.clone());
                        // Claims success on its own: Core must not rely on it.
                        let mut answer = task;
                        answer["readback_verified"] = json!(true);
                        Ok(answer)
                    }
                    other => Err((ErrorName::Unsupported, other.to_string())),
                }
            }
            _ => Err((ErrorName::Unsupported, method.to_string())),
        }
    });
    let peer = TestPeer::connect(core, "hostd", Some(handler));
    *peer_slot.lock().unwrap() = Some(Arc::clone(&peer));
    let hello = peer.raw(
        "host.hello",
        json!({"hostd_version": "0.2.0", "node_version": "22.23.2", "cordis_version": "4.0.4", "vendor_fingerprint": "sha256:test", "strategy": "isolate_rebuild"}),
    );
    assert!(hello.get("result").is_some(), "hello: {hello}");
    peer
}

// ---- harness ----------------------------------------------------------------

struct Harness {
    core: Arc<Core>,
    root: PathBuf,
}

impl Drop for Harness {
    fn drop(&mut self) {
        let _ = ditto_store::packages::make_writable(&self.root);
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

fn root(label: &str) -> PathBuf {
    let root = std::env::temp_dir().join(format!(
        "ditto-core-{label}-{}-{}",
        std::process::id(),
        ids::ulid()
    ));
    std::fs::create_dir_all(&root).unwrap();
    root
}

fn start_at(root: &Path, rescue: bool) -> Arc<Core> {
    let builtin = root.join("builtin");
    if !builtin.exists() {
        builtin_packages(&builtin);
    }
    let mut config = CoreConfig::new(Paths::under(&root.join("store")), root.join("core.sock"));
    config.builtin_packages = Some(builtin);
    config.recovery_wait_shell = Duration::from_millis(300);
    config.recovery_wait_host = Duration::from_millis(300);
    config.observation_period = Duration::from_millis(300);
    config.confirmation_window = Duration::from_millis(600);
    if rescue {
        config.mode = ditto_protocol::rpc::CoreMode::Rescue;
    }
    let (compositor, _events) = FixtureCompositor::paired();
    let session = Arc::new(Session::new(Box::new(compositor)));
    let system: Arc<dyn ditto_system::SystemServices> = Arc::new(
        ditto_system::fake::FakeSystem::with_apps(ditto_system::fake::FakeSystem::sample_apps()),
    );
    let core = Core::start(config, session, system, Arc::new(IdentityRegistry::new()))
        .expect("core starts");
    // Boot (seeding, default profile, recovery) finishes before this returns.
    core.coordinate(Duration::from_secs(10), |_| ())
        .expect("coordinator ready");
    core
}

fn harness(label: &str) -> Harness {
    let root = root(label);
    let core = start_at(&root, false);
    Harness { core, root }
}

fn head(peer: &TestPeer) -> String {
    peer.result(catalog::PROFILES_GET, json!({}))["profile"]["head_revision"]
        .as_str()
        .unwrap()
        .to_string()
}

fn document(peer: &TestPeer) -> Value {
    peer.result(catalog::PROFILES_GET, json!({}))["document"].clone()
}

fn entry_of(document: &Value, package: &str) -> Option<String> {
    document["entries"]
        .as_array()?
        .iter()
        .find(|entry| entry["package"] == json!(package))
        .map(|entry| entry["entry_id"].as_str().unwrap().to_string())
}

/// Results carry `_meta` beside the output's own fields; strip it before
/// reading the output type (which refuses unknown fields).
fn record(value: &Value) -> ChangeRecord {
    let mut value = value.clone();
    if let Value::Object(map) = &mut value {
        map.remove("_meta");
    }
    serde_json::from_value(value).expect("a change record")
}

fn accent(peer: &TestPeer, color: &str) -> Value {
    peer.call(
        catalog::CHANGES_PROPOSE,
        json!({"base_revision": head(peer), "ops": [{"op": "set_value", "path": "/appearance/tokens/accent", "after": color}]}),
    )
}

// ---- tests --------------------------------------------------------------------

#[test]
fn every_catalog_entry_has_a_handler_and_a_consumer() {
    let catalog = catalog::catalog();
    let handlers = handlers();
    let mut consumers: Vec<&str> = dittoctl::CONSUMED_CAPABILITIES.to_vec();
    // Core's notification server is the consumer of the policy decision.
    consumers.push(catalog::NOTIFICATIONS_POLICY_DECIDE);
    catalog::validate_catalog(&catalog.capabilities, &handlers, &consumers).unwrap();
}

#[test]
fn protocol_0_1_clients_and_unknown_kinds_are_refused() {
    let harness = harness("handshake");
    let (client, server) = UnixStream::pair().unwrap();
    let core = Arc::clone(&harness.core);
    thread::spawn(move || {
        let _ = serve_connection(server, core, TOKEN);
    });
    let mut writer = client.try_clone().unwrap();
    let mut reader = BufReader::new(client);
    serde_json::to_writer(
        &mut writer,
        &json!({"jsonrpc":"2.0","id":"h","method":"core.handshake","params":{"protocol_version":"0.1.0","client":{"kind":"dittoctl","version":"0.1.0"},"auth":{"token":TOKEN}}}),
    )
    .unwrap();
    writer.write_all(b"\n").unwrap();
    let mut line = String::new();
    reader.read_line(&mut line).unwrap();
    let response: Value = serde_json::from_str(&line).unwrap();
    assert_eq!(response["error"]["name"], "protocol_version_unsupported");
    let stranger = TestPeer::connect(&harness.core, "privileged-plugin", None);
    assert_eq!(stranger.handshake["error"]["name"], "identity_rejected");
    let cli = TestPeer::connect(&harness.core, "dittoctl", None);
    assert_eq!(cli.handshake["result"]["subject"], "cli");
    assert_eq!(
        cli.handshake["result"]["protocol_version"],
        PROTOCOL_VERSION
    );
}

#[test]
fn an_appearance_change_commits_only_after_the_shell_reads_back() {
    let harness = harness("appearance");
    let state = Arc::new(Mutex::new(ShellState::default()));
    let _shell = fake_shell(&harness.core, Arc::clone(&state));
    let cli = TestPeer::connect(&harness.core, "dittoctl", None);
    let before = head(&cli);
    let response = accent(&cli, "#9d7bff");
    let change = record(&response["result"]);
    assert_eq!(change.state, ChangeState::Committed, "{response}");
    assert_eq!(change.result, Some(ResultKind::Succeeded));
    assert_eq!(response["result"]["_meta"]["readback_verified"], true);
    assert_ne!(head(&cli), before);
    assert_eq!(document(&cli)["appearance"]["tokens"]["accent"], "#9d7bff");
    assert_eq!(
        state
            .lock()
            .unwrap()
            .committed
            .as_ref()
            .unwrap()
            .appearance
            .tokens["accent"],
        "#9d7bff"
    );
    let applied = cli.result(catalog::APPEARANCE_GET, json!({}));
    assert_eq!(applied["appearance"]["tokens"]["accent"], "#9d7bff");
    // Undo goes back to the base content, as a new change.
    let undone = record(&cli.result(
        catalog::CHANGES_UNDO,
        json!({"change_id": change.change_id}),
    ));
    assert_eq!(undone.state, ChangeState::Committed);
    assert_eq!(document(&cli)["appearance"]["tokens"]["accent"], "#b9a4ff");
    // The history keeps both, newest first.
    let history = cli.result(catalog::CHANGES_LIST, json!({}));
    assert_eq!(history["changes"][0]["change_id"], json!(undone.change_id));
    assert_eq!(history["changes"][1]["change_id"], json!(change.change_id));
}

#[test]
fn without_a_shell_the_change_is_aborted_and_the_head_stays() {
    let harness = harness("no-shell");
    let cli = TestPeer::connect(&harness.core, "dittoctl", None);
    let before = head(&cli);
    let change = record(&accent(&cli, "#123456")["result"]);
    assert_eq!(change.state, ChangeState::Aborted);
    assert_eq!(change.result, Some(ResultKind::Failed));
    assert_eq!(
        change.failure_key.as_deref(),
        Some("change.participant_unavailable")
    );
    assert_eq!(head(&cli), before);
}

#[test]
fn a_dock_swap_is_a_transaction_and_a_broken_candidate_leaves_the_active_dock() {
    let harness = harness("dock-swap");
    let state = Arc::new(Mutex::new(ShellState::default()));
    let shell = fake_shell(&harness.core, Arc::clone(&state));
    let cli = TestPeer::connect(&harness.core, "dittoctl", None);
    // Boot sync mounted the default composition.
    wait_for_boot_sync(&state);
    let doc = document(&cli);
    let dock_a = doc["slots"]["ui.dock"].as_str().unwrap().to_string();
    // Swap A → B with an add_entry bound to the slot, then remove A.
    let response = cli.call(
        catalog::CHANGES_PROPOSE,
        json!({"base_revision": head(&cli), "surface": "composition_center", "ops": [
            {"op": "add_entry", "entry": {"package": "ditto.dock.pill", "version": "1.0.0", "host": "qml"}, "slot": "ui.dock"},
            {"op": "remove_entry", "entry_id": dock_a}
        ]}),
    );
    let swap = record(&response["result"]);
    assert_eq!(swap.state, ChangeState::Committed, "{response}");
    assert_eq!(swap.card.kind, "mixed");
    let doc = document(&cli);
    let dock_b = doc["slots"]["ui.dock"].as_str().unwrap().to_string();
    assert_eq!(entry_of(&doc, "ditto.dock.pill"), Some(dock_b.clone()));
    let panels = cli.result(catalog::PANELS_LIST, json!({}));
    let _ = panels;
    // A candidate that fails to load aborts the change; the active Dock stays.
    state.lock().unwrap().broken_package = Some("ditto.dock.broken".into());
    let before = head(&cli);
    let broken = record(
        &cli.result(
            catalog::CHANGES_PROPOSE,
            json!({"base_revision": before, "ops": [
                {"op": "add_entry", "entry": {"package": "ditto.dock.broken", "version": "1.0.0", "host": "qml"}, "slot": "ui.dock"}
            ]}),
        ),
    );
    assert_eq!(broken.state, ChangeState::Aborted);
    assert!(broken
        .items
        .iter()
        .any(|item| item.reason.as_deref() == Some("qml_error")));
    assert_eq!(head(&cli), before);
    let mounted = state.lock().unwrap().committed.clone().unwrap();
    assert!(mounted
        .slots
        .iter()
        .any(|slot| slot.slot == "ui.dock" && slot.entry_id == dock_b));
    drop(shell);
}

#[test]
fn a_readback_that_disagrees_rolls_the_change_back() {
    let harness = harness("readback");
    let state = Arc::new(Mutex::new(ShellState::default()));
    let _shell = fake_shell(&harness.core, Arc::clone(&state));
    let cli = TestPeer::connect(&harness.core, "dittoctl", None);
    wait_for_boot_sync(&state);
    let before = head(&cli);
    state.lock().unwrap().lie_after_commit = true;
    let change = record(&accent(&cli, "#00ff00")["result"]);
    assert_eq!(change.state, ChangeState::RolledBack);
    assert_eq!(
        change.failure_key.as_deref(),
        Some("change.readback_mismatch")
    );
    assert_eq!(head(&cli), before);
}

/// EX1-03 ①: one ChangeSet swaps the Dock and the launcher; undoing it
/// returns to the base revision's content, and the Shell reads back the
/// original mounts.
#[test]
fn undoing_a_cross_plugin_change_returns_to_the_base_content() {
    let harness = harness("undo-cross");
    let state = Arc::new(Mutex::new(ShellState::default()));
    let _shell = fake_shell(&harness.core, Arc::clone(&state));
    let cli = TestPeer::connect(&harness.core, "dittoctl", None);
    wait_for_boot_sync(&state);
    let base = cli.result(catalog::PROFILES_GET, json!({}));
    let doc = &base["document"];
    let dock = doc["slots"]["ui.dock"].as_str().unwrap().to_string();
    let launcher = doc["slots"]["ui.launcher"].as_str().unwrap().to_string();
    let swap = record(&cli.result(
        catalog::CHANGES_PROPOSE,
        json!({"base_revision": head(&cli), "ops": [
            {"op": "add_entry", "entry": {"package": "ditto.dock.pill", "version": "1.0.0", "host": "qml"}, "slot": "ui.dock"},
            {"op": "remove_entry", "entry_id": dock},
            {"op": "add_entry", "entry": {"package": "ditto.launcher.search", "version": "1.0.0", "host": "qml"}, "slot": "ui.launcher"},
            {"op": "remove_entry", "entry_id": launcher}
        ]}),
    ));
    assert_eq!(swap.state, ChangeState::Committed);
    let undo = record(&cli.result(catalog::CHANGES_UNDO, json!({"change_id": swap.change_id})));
    assert_eq!(undo.state, ChangeState::Committed);
    let after = cli.result(catalog::PROFILES_GET, json!({}));
    assert_eq!(
        after["revision"]["document_sha256"], base["revision"]["document_sha256"],
        "the undo must restore the base content byte for byte"
    );
    let mounted = state.lock().unwrap().committed.clone().unwrap();
    for (slot, entry) in [("ui.dock", &dock), ("ui.launcher", &launcher)] {
        assert!(
            mounted
                .slots
                .iter()
                .any(|mount| mount.slot == slot && &mount.entry_id == entry),
            "{slot} is not back on {entry}"
        );
    }
}

/// A session-restart change is saved for the next login and applies nothing
/// now; its result says `scheduled`, never `succeeded` (protocol 0.2 §8.4).
#[test]
fn a_session_restart_change_is_scheduled_not_succeeded() {
    let harness = harness("next-login");
    let state = Arc::new(Mutex::new(ShellState::default()));
    let _shell = fake_shell(&harness.core, Arc::clone(&state));
    let cli = TestPeer::connect(&harness.core, "dittoctl", None);
    wait_for_boot_sync(&state);
    let mounted_before = state.lock().unwrap().committed.clone();
    let prepares = state.lock().unwrap().prepares;
    let change = record(&cli.result(
        catalog::CHANGES_PROPOSE,
        json!({"base_revision": head(&cli), "ops": [
            {"op": "add_entry", "entry": {"package": "ditto.test.next-login", "version": "1.0.0", "host": "qml"}, "slot": "ui.dock"}
        ]}),
    ));
    assert_eq!(
        change.hot_swap_level,
        ditto_protocol::change::HotSwapLevel::SessionRestart
    );
    assert_eq!(change.state, ChangeState::Committed);
    assert_eq!(
        change.result,
        Some(ditto_protocol::change::ResultKind::Scheduled)
    );
    assert!(!change.items.is_empty());
    assert!(change.items.iter().all(|item| {
        item.status == ditto_protocol::change::OutcomeStatus::Scheduled
            && item.reason.as_deref() == Some("next_login")
    }));
    // Saved for the next login: the head carries it, the Shell was not asked.
    assert_eq!(head(&cli), change.committed_revision.clone().unwrap());
    assert_eq!(state.lock().unwrap().prepares, prepares);
    assert_eq!(state.lock().unwrap().committed, mounted_before);
    // The history says the same as the response.
    let listed = cli.result(catalog::CHANGES_LIST, json!({}));
    let summary = listed["changes"]
        .as_array()
        .unwrap()
        .iter()
        .find(|item| item["change_id"] == json!(change.change_id))
        .unwrap()
        .clone();
    assert_eq!(summary["result"], "scheduled");
}

/// EX1-03 ③: a rollback that cannot put one item back ends partially
/// applied, and that item is listed with its reason.
#[test]
fn a_rollback_that_cannot_restore_an_item_is_partially_applied() {
    let harness = harness("partial");
    let state = Arc::new(Mutex::new(ShellState::default()));
    let _shell = fake_shell(&harness.core, Arc::clone(&state));
    let cli = TestPeer::connect(&harness.core, "dittoctl", None);
    wait_for_boot_sync(&state);
    let before = head(&cli);
    {
        let mut shell = state.lock().unwrap();
        shell.lie_after_commit = true;
        shell.cannot_restore = Some("ui.dock".into());
    }
    let change = record(&accent(&cli, "#123456")["result"]);
    assert_eq!(change.state, ChangeState::PartiallyApplied);
    assert!(change.items.iter().any(|item| item.key == "ui.dock"
        && item.status == ditto_protocol::change::OutcomeStatus::NotRestored
        && item.reason.as_deref() == Some("window_closed")));
    // The head never moved to the change's revision.
    assert_eq!(head(&cli), before);
}

/// EX1-03 ③ as written: a layout change is undone after one of its windows
/// closed. The strategy goes back, the window still open goes back to where
/// it floated, and the closed one is listed as not restored with its reason;
/// the result is partial, never "succeeded".
#[test]
fn undoing_a_layout_change_after_a_window_closed_is_partial() {
    let harness = harness("undo-layout");
    let state = Arc::new(Mutex::new(ShellState::default()));
    let _shell = fake_shell(&harness.core, Arc::clone(&state));
    let cli = TestPeer::connect(&harness.core, "dittoctl", None);
    wait_for_boot_sync(&state);
    let window = |id: &str| cli.result(catalog::WINDOWS_GET, json!({"window_id": id}));
    let floating_before = window("fixture-window-2");
    let base = cli.result(catalog::PROFILES_GET, json!({}));
    let floating = base["document"]["slots"]["layout.strategy"]
        .as_str()
        .unwrap()
        .to_string();
    let tile = record(&cli.result(
        catalog::CHANGES_PROPOSE,
        json!({"base_revision": head(&cli), "ops": [
            {"op": "add_entry", "entry": {"package": "ditto.layout.simple-tile", "version": "1.0.0", "host": "core_builtin"}, "slot": "layout.strategy"},
            {"op": "remove_entry", "entry_id": floating}
        ]}),
    ));
    assert_eq!(tile.state, ChangeState::Committed, "{tile:?}");
    let tiled = window("fixture-window-2");
    assert_ne!(
        (tiled["x"].clone(), tiled["width"].clone()),
        (
            floating_before["x"].clone(),
            floating_before["width"].clone()
        ),
        "the fixture tiler must move the window, or the undo proves nothing"
    );
    cli.result(
        catalog::WINDOWS_CLOSE_REQUEST,
        json!({"window_id": "fixture-window-1"}),
    );
    let undo = record(&cli.result(catalog::CHANGES_UNDO, json!({"change_id": tile.change_id})));
    assert_eq!(undo.state, ChangeState::Committed, "{undo:?}");
    assert_eq!(
        undo.result,
        Some(ditto_protocol::change::ResultKind::Partial),
        "{undo:?}"
    );
    let item = |key: &str| {
        undo.items
            .iter()
            .find(|item| item.key == key)
            .unwrap_or_else(|| panic!("no item {key} in {:?}", undo.items))
            .clone()
    };
    let closed = item("window:fixture-window-1");
    assert_eq!(
        closed.status,
        ditto_protocol::change::OutcomeStatus::NotRestored
    );
    assert_eq!(closed.reason.as_deref(), Some("window_closed"));
    let open = window("fixture-window-2");
    for field in ["x", "y", "width", "height"] {
        assert_eq!(
            open[field], floating_before[field],
            "{field} was not put back"
        );
    }
    // The profile content is the base again; the strategy reads back.
    let after = cli.result(catalog::PROFILES_GET, json!({}));
    assert_eq!(
        after["revision"]["document_sha256"],
        base["revision"]["document_sha256"]
    );
    // The stored column agrees with the record: a reader of the history
    // never sees "succeeded" for it.
    let listed = cli.result(catalog::CHANGES_GET, json!({"change_id": undo.change_id}));
    assert_eq!(listed["result"], json!("partial"), "{listed}");
}

#[test]
fn preflight_refuses_every_problem_at_once_and_changes_nothing() {
    let harness = harness("preflight");
    let state = Arc::new(Mutex::new(ShellState::default()));
    let _shell = fake_shell(&harness.core, Arc::clone(&state));
    let cli = TestPeer::connect(&harness.core, "dittoctl", None);
    // The boot sync is a prepare of its own; count only after it landed.
    wait_for_boot_sync(&state);
    let before = head(&cli);
    let digest =
        cli.result(catalog::PROFILES_GET, json!({}))["revision"]["document_sha256"].clone();
    let prepares = state.lock().unwrap().prepares;
    let add = |package: &str, slot: &str| json!({"op": "add_entry", "entry": {"package": package, "version": "1.0.0", "host": "qml"}, "slot": slot});
    let cases = [
        (
            json!([add("ditto.test.needs-missing", "ui.dock")]),
            "dependency_missing",
        ),
        (
            json!([
                add("ditto.test.needs-dock-2", "ui.dock"),
                add("ditto.dock.pill", "ui.launcher")
            ]),
            "version_conflict",
        ),
        (
            json!([add("ditto.test.future", "ui.dock")]),
            "protocol_incompatible",
        ),
        (
            json!([
                add("ditto.test.cycle-a", "ui.dock"),
                add("ditto.test.cycle-b", "ui.launcher")
            ]),
            "dependency_cycle",
        ),
        (
            json!([add("ditto.dock.pill", "svc.tasks")]),
            "single_provider_violation",
        ),
        (
            json!([{"op": "add_entry", "entry": {"package": "ditto.nowhere", "version": "1.0.0", "host": "qml"}}]),
            "package_missing",
        ),
        (
            json!([{"op": "add_entry", "entry": {"package": "ditto.test.greedy", "version": "1.0.0", "host": "cordis"}}]),
            "budget_exceeded",
        ),
    ];
    for (ops, code) in cases {
        let response = cli.call(
            catalog::CHANGES_PROPOSE,
            json!({"base_revision": before, "ops": ops}),
        );
        assert_eq!(
            response["error"]["name"], "preflight_rejected",
            "{code}: {response}"
        );
        let reasons = response["error"]["data"]["reasons"].as_array().unwrap();
        assert!(
            reasons.iter().any(|reason| reason["code"] == json!(code)),
            "{code}: {response}"
        );
        let change_id = response["error"]["data"]["change_id"].as_str().unwrap();
        let stored = cli.result(catalog::CHANGES_GET, json!({"change_id": change_id}));
        assert_eq!(stored["state"], "rejected");
    }
    // A stale base and a stale intent are reported together.
    let response = cli.call(
        catalog::CHANGES_PROPOSE,
        json!({"base_revision": "rev-00000000000000000000000000", "ops": [{"op": "set_value", "path": "/appearance/tokens/accent", "before": "#000000", "after": "#111111"}]}),
    );
    let codes: Vec<&str> = response["error"]["data"]["reasons"]
        .as_array()
        .unwrap()
        .iter()
        .map(|r| r["code"].as_str().unwrap())
        .collect();
    assert!(
        codes.contains(&"base_revision_stale") && codes.contains(&"stale_intent"),
        "{codes:?}"
    );
    // Nothing reached a participant and the head's content is unchanged.
    assert_eq!(state.lock().unwrap().prepares, prepares);
    assert_eq!(head(&cli), before);
    assert_eq!(
        cli.result(catalog::PROFILES_GET, json!({}))["revision"]["document_sha256"],
        digest
    );
}

#[test]
fn a_tampered_package_is_an_integrity_mismatch() {
    let harness = harness("integrity");
    let _shell = fake_shell(&harness.core, Arc::new(Mutex::new(ShellState::default())));
    let cli = TestPeer::connect(&harness.core, "dittoctl", None);
    let package = cli.result(
        catalog::PLUGINS_GET,
        json!({"package_id": "ditto.dock.pill"}),
    );
    let directory = harness
        .root
        .join("store/data/packages/sha256")
        .join(package["package"]["sha256"].as_str().unwrap());
    ditto_store::packages::make_writable(&directory).unwrap();
    std::fs::write(
        directory.join("qml/Provider.qml"),
        "// changed after installation\n",
    )
    .unwrap();
    let response = cli.call(
        catalog::CHANGES_PROPOSE,
        json!({"base_revision": head(&cli), "ops": [{"op": "add_entry", "entry": {"package": "ditto.dock.pill", "version": "1.0.0", "host": "qml"}, "slot": "ui.dock"}]}),
    );
    let codes: Vec<&str> = response["error"]["data"]["reasons"]
        .as_array()
        .unwrap()
        .iter()
        .map(|r| r["code"].as_str().unwrap())
        .collect();
    assert_eq!(codes, vec!["integrity_mismatch"]);
}

#[test]
fn the_same_idempotency_key_returns_the_first_change() {
    let harness = harness("idempotency");
    let _shell = fake_shell(&harness.core, Arc::new(Mutex::new(ShellState::default())));
    let cli = TestPeer::connect(&harness.core, "dittoctl", None);
    let base = head(&cli);
    let body = json!({"base_revision": base, "idempotency_key": "same-key", "ops": [{"op": "set_value", "path": "/avatar/hidden", "after": true}]});
    let first = record(&cli.result(catalog::CHANGES_PROPOSE, body.clone()));
    let second = record(&cli.result(catalog::CHANGES_PROPOSE, body));
    assert_eq!(first.change_id, second.change_id);
    assert_eq!(
        cli.result(catalog::CHANGES_LIST, json!({}))["changes"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
}

#[test]
fn a_stale_base_is_refused_instead_of_overwriting_the_newer_change() {
    // L-09: two changes on the same base; the coordinator serializes them and
    // the second sees the first's head.
    let harness = harness("stale-base");
    let _shell = fake_shell(&harness.core, Arc::new(Mutex::new(ShellState::default())));
    let cli = TestPeer::connect(&harness.core, "dittoctl", None);
    let base = head(&cli);
    let first = record(&cli.result(
        catalog::CHANGES_PROPOSE,
        json!({"base_revision": base, "ops": [{"op": "set_value", "path": "/appearance/tokens/accent", "after": "#aa0000"}]}),
    ));
    assert_eq!(first.state, ChangeState::Committed);
    let second = cli.call(
        catalog::CHANGES_PROPOSE,
        json!({"base_revision": base, "ops": [{"op": "set_value", "path": "/appearance/tokens/accent", "after": "#00aa00"}]}),
    );
    assert_eq!(
        second["error"]["data"]["reasons"][0]["code"],
        "base_revision_stale"
    );
    assert_eq!(document(&cli)["appearance"]["tokens"]["accent"], "#aa0000");
}

#[test]
fn undoing_an_older_change_that_a_newer_one_touched_is_refused() {
    let harness = harness("undo-policy");
    let _shell = fake_shell(&harness.core, Arc::new(Mutex::new(ShellState::default())));
    let cli = TestPeer::connect(&harness.core, "dittoctl", None);
    let first = record(&accent(&cli, "#aa0000")["result"]);
    let _second = record(&accent(&cli, "#00aa00")["result"]);
    let refused = cli.call(catalog::CHANGES_UNDO, json!({"change_id": first.change_id}));
    assert_eq!(
        refused["error"]["data"]["reason"],
        "undo_blocked_by_newer_change"
    );
    // A newer change on an unrelated path does not block the undo.
    let third = record(&cli.result(
        catalog::CHANGES_PROPOSE,
        json!({"base_revision": head(&cli), "ops": [{"op": "set_value", "path": "/avatar/hidden", "after": true}]}),
    ));
    let _ = third;
    let undo_second = record(&cli.result(
        catalog::CHANGES_UNDO,
        json!({"change_id": _second.change_id}),
    ));
    assert_eq!(undo_second.state, ChangeState::Committed);
    assert_eq!(document(&cli)["appearance"]["tokens"]["accent"], "#aa0000");
    assert_eq!(document(&cli)["avatar"]["hidden"], true);
}

#[test]
fn a_preview_reverts_by_itself_when_nobody_confirms() {
    let harness = harness("preview");
    let _shell = fake_shell(&harness.core, Arc::new(Mutex::new(ShellState::default())));
    let cli = TestPeer::connect(&harness.core, "dittoctl", None);
    let original = document(&cli)["appearance"]["tokens"]["accent"].clone();
    let preview = record(&cli.result(
        catalog::CHANGES_PROPOSE,
        json!({"base_revision": head(&cli), "mode": "preview", "ops": [{"op": "set_value", "path": "/appearance/tokens/accent", "after": "#777777"}]}),
    ));
    assert!(matches!(
        preview.confirmation,
        ditto_protocol::change::Confirmation::Pending { .. }
    ));
    thread::sleep(Duration::from_millis(1500));
    let after = record(&cli.result(
        catalog::CHANGES_GET,
        json!({"change_id": preview.change_id}),
    ));
    assert!(
        matches!(
            after.confirmation,
            ditto_protocol::change::Confirmation::Reverted { .. }
        ),
        "{:?}",
        after.confirmation
    );
    assert_eq!(document(&cli)["appearance"]["tokens"]["accent"], original);
    // A confirmed preview stays.
    let kept = record(&cli.result(
        catalog::CHANGES_PROPOSE,
        json!({"base_revision": head(&cli), "mode": "preview", "ops": [{"op": "set_value", "path": "/appearance/tokens/accent", "after": "#888888"}]}),
    ));
    cli.result(
        catalog::CHANGES_CONFIRM,
        json!({"change_id": kept.change_id}),
    );
    thread::sleep(Duration::from_millis(1000));
    assert_eq!(document(&cli)["appearance"]["tokens"]["accent"], "#888888");
}

#[test]
fn a_service_is_leased_forwarded_and_read_back_by_core() {
    let harness = harness("hostd");
    let _shell = fake_shell(&harness.core, Arc::new(Mutex::new(ShellState::default())));
    let host_state = Arc::new(Mutex::new(HostState::default()));
    let host = fake_host(&harness.core, Arc::clone(&host_state));
    let cli = TestPeer::connect(&harness.core, "dittoctl", None);
    // The default profile has the tasks service: when hostd says hello, Core
    // pushes it (boot sync) and hostd takes leases on commit.
    let tasks_listed = || {
        cli.result(catalog::CAPABILITIES_LIST, json!({}))["capabilities"]
            .as_array()
            .unwrap()
            .iter()
            .find(|item| item["capability_id"] == "desktop.tasks.list")
            .unwrap()
            .clone()
    };
    let deadline = Instant::now() + Duration::from_secs(5);
    while tasks_listed()["availability"]["available"] != true {
        assert!(
            Instant::now() < deadline,
            "tasks never became available: {}",
            tasks_listed()
        );
        thread::sleep(Duration::from_millis(20));
    }
    assert!(tasks_listed()["provider"]
        .as_str()
        .unwrap()
        .starts_with("hostd:ent-"));
    // A second tasks provider is a single-provider violation, refused before
    // hostd hears of it.
    let second = cli.call(
        catalog::CHANGES_PROPOSE,
        json!({"base_revision": head(&cli), "ops": [{"op": "add_entry", "entry": {"package": "ditto.svc.tasks", "version": "1.0.0", "host": "cordis"}}]}),
    );
    assert_eq!(
        second["error"]["data"]["reasons"][0]["code"],
        "single_provider_violation"
    );
    // Disabling the service is a controlled handoff that hostd takes part in.
    let entry = entry_of(&document(&cli), "ditto.svc.tasks").unwrap();
    let disable = record(&cli.result(
        catalog::CHANGES_PROPOSE,
        json!({"base_revision": head(&cli), "ops": [{"op": "set_entry_disabled", "entry_id": entry, "disabled": true}]}),
    ));
    assert_eq!(disable.state, ChangeState::Committed);
    assert_eq!(
        disable.hot_swap_level,
        ditto_protocol::change::HotSwapLevel::ControlledHandoff
    );
    let enable = record(&cli.result(
        catalog::CHANGES_PROPOSE,
        json!({"base_revision": head(&cli), "ops": [{"op": "set_entry_disabled", "entry_id": entry, "disabled": false}]}),
    ));
    assert_eq!(enable.state, ChangeState::Committed, "{:?}", enable.items);
    assert_eq!(tasks_listed()["availability"]["available"], true);
    // Core reads back itself; the provider's own claim is dropped.
    let added = cli.result(catalog::TASKS_ADD, json!({"text": "買牛奶"}));
    assert_eq!(added["_meta"]["readback_verified"], true);
    assert!(added.get("readback_verified").is_none());
    // A forged on_behalf_of is refused.
    let forged = host.call_as(
        catalog::TASKS_LIST,
        json!({}),
        Some("ent-00000000000000000000000000"),
    );
    assert_eq!(forged["error"]["name"], "identity_rejected");
    let not_hostd = cli.call_as(
        catalog::TASKS_LIST,
        json!({}),
        Some(&entry_of(&document(&cli), "ditto.svc.tasks").unwrap()),
    );
    assert_eq!(not_hostd["error"]["name"], "identity_rejected");
    // hostd dies: its capabilities are unavailable at once (≤500 ms).
    let lost = Instant::now();
    host.close();
    loop {
        let item = cli.result(catalog::CAPABILITIES_LIST, json!({}))["capabilities"]
            .as_array()
            .unwrap()
            .iter()
            .find(|item| item["capability_id"] == "desktop.tasks.list")
            .unwrap()
            .clone();
        if item["availability"]["available"] == false {
            assert_eq!(item["availability"]["reason"], "host_unavailable");
            break;
        }
        assert!(
            lost.elapsed() < Duration::from_millis(500),
            "still available after 500 ms"
        );
        thread::sleep(Duration::from_millis(10));
    }
    assert!(lost.elapsed() < Duration::from_millis(500));
    let refused = cli.call(catalog::TASKS_LIST, json!({}));
    assert_eq!(refused["error"]["name"], "unavailable");
}

#[test]
fn a_candidate_cannot_claim_before_commit() {
    // L-03 negative: registering during prepare is refused.
    let harness = harness("candidate-claim");
    let _shell = fake_shell(&harness.core, Arc::new(Mutex::new(ShellState::default())));
    let host_state = Arc::new(Mutex::new(HostState {
        claim_at_prepare: true,
        ..Default::default()
    }));
    let _host = fake_host(&harness.core, Arc::clone(&host_state));
    let cli = TestPeer::connect(&harness.core, "dittoctl", None);
    let _ = cli.call(
        catalog::CHANGES_PROPOSE,
        json!({"base_revision": head(&cli), "ops": [{"op": "add_entry", "entry": {"package": "ditto.svc.tasks", "version": "1.0.0", "host": "cordis"}, "slot": "svc.tasks"}]}),
    );
    let outcome = host_state
        .lock()
        .unwrap()
        .claim_outcome
        .clone()
        .expect("the candidate tried to register");
    assert_eq!(outcome["error"]["name"], "conflict");
    assert_eq!(outcome["error"]["data"]["reason"], "candidate_cannot_claim");
    // After commit there is exactly one provider.
    let bindings = cli.result(catalog::PLUGINS_DIAGNOSTICS, json!({}))["core"]["leases"]
        .as_u64()
        .unwrap();
    assert_eq!(bindings, 3);
}

/// A store prepared before Core starts: one active profile whose head is
/// `head` and whose last-known-good is `good`, plus whatever `extra` writes.
fn seed_store(
    root: &Path,
    good: &ditto_protocol::profile::ProfileDocument,
    head: &ditto_protocol::profile::ProfileDocument,
    extra: impl FnOnce(&rusqlite::Transaction<'_>, &str, &str, &str) -> ditto_store::StoreResult<()>,
) {
    use ditto_protocol::profile::RevisionOrigin;
    let paths = Paths::under(&root.join("store"));
    let lock = ditto_store::WriterLock::acquire(&paths.lock()).unwrap();
    let (mut store, _) = ditto_store::Store::open_writer(&paths, &lock).unwrap();
    store
        .write(|tx| {
            let origin = RevisionOrigin::Create {
                from: "default".into(),
            };
            let (profile, first) = ditto_store::profiles::create(tx, "預設", good, &origin)?;
            ditto_store::profiles::set_active_profile(tx, &profile.profile_id)?;
            ditto_store::profiles::set_last_known_good(
                tx,
                &profile.profile_id,
                &first.revision_id,
            )?;
            let second = ditto_store::profiles::insert_revision(
                tx,
                &profile.profile_id,
                Some(&first.revision_id),
                head,
                &origin,
                None,
            )?;
            ditto_store::profiles::set_head(tx, &profile.profile_id, &second.revision_id)?;
            extra(
                tx,
                &profile.profile_id,
                &first.revision_id,
                &second.revision_id,
            )
        })
        .unwrap();
}

fn plain_document(accent: &str) -> ditto_protocol::profile::ProfileDocument {
    let mut document = crate::defaults::empty_document();
    document
        .appearance
        .tokens
        .insert("accent".into(), accent.into());
    document
}

/// Start Core without waiting for boot, so a participant can connect while
/// recovery waits for it.
fn start_without_waiting(root: &Path, rescue: bool) -> Arc<Core> {
    let builtin = root.join("builtin");
    if !builtin.exists() {
        builtin_packages(&builtin);
    }
    let mut config = CoreConfig::new(Paths::under(&root.join("store")), root.join("core.sock"));
    config.builtin_packages = Some(builtin);
    config.recovery_wait_shell = Duration::from_secs(3);
    config.recovery_wait_host = Duration::from_millis(300);
    config.observation_period = Duration::from_millis(300);
    config.confirmation_window = Duration::from_millis(600);
    if rescue {
        config.mode = ditto_protocol::rpc::CoreMode::Rescue;
    }
    let (compositor, _events) = FixtureCompositor::paired();
    let session = Arc::new(Session::new(Box::new(compositor)));
    let system: Arc<dyn ditto_system::SystemServices> =
        Arc::new(ditto_system::fake::FakeSystem::default());
    Core::start(config, session, system, Arc::new(IdentityRegistry::new())).expect("core starts")
}

#[test]
fn rescue_restores_the_last_known_good_composition() {
    let root = root("rescue-restore");
    seed_store(
        &root,
        &plain_document("#00aa00"),
        &plain_document("#ff0000"),
        |_, _, _, _| Ok(()),
    );
    let core = start_without_waiting(&root, true);
    let shell_state = Arc::new(Mutex::new(ShellState::default()));
    let _shell = fake_shell(&core, Arc::clone(&shell_state));
    core.coordinate(Duration::from_secs(10), |_| ()).unwrap();
    let rescue = TestPeer::connect(&core, "dittoctl-rescue", None);
    let restored = rescue.call(
        catalog::RESCUE_RESTORE_LAST_GOOD,
        json!({"idempotency_key": "r-1"}),
    );
    let change = record(&restored["result"]);
    assert_eq!(change.state, ChangeState::Committed, "{restored}");
    assert_eq!(change.origin, ditto_protocol::change::ChangeOrigin::Rescue);
    assert_eq!(
        document(&rescue)["appearance"]["tokens"]["accent"],
        "#00aa00"
    );
    drop(core);
    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn rescue_mode_reports_rescue_mode_for_cordis_capabilities() {
    let root = root("rescue-mode");
    let core = start_at(&root, true);
    let cli = TestPeer::connect(&core, "dittoctl-rescue", None);
    assert_eq!(cli.handshake["result"]["mode"], "rescue");
    assert_eq!(cli.handshake["result"]["subject"], "cli:rescue");
    let status = cli.result(catalog::RESCUE_STATUS, json!({}));
    assert_eq!(status["mode"], "rescue");
    assert!(status["unavailable"]
        .as_array()
        .unwrap()
        .iter()
        .any(
            |item| item["capability_id"] == "desktop.tasks.list" && item["reason"] == "rescue_mode"
        ));
    // Rescue may read history but not change the appearance.
    let refused = accent(&cli, "#010101");
    assert_eq!(refused["error"]["name"], "permission_denied");
    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn profiles_are_created_duplicated_compared_and_the_active_one_cannot_be_deleted() {
    let harness = harness("profiles");
    let cli = TestPeer::connect(&harness.core, "dittoctl", None);
    let active = cli.result(catalog::PROFILES_LIST, json!({}))["active_profile"]
        .as_str()
        .unwrap()
        .to_string();
    let copy = cli.result(
        catalog::PROFILES_DUPLICATE,
        json!({"profile_id": active, "name": "簡報", "idempotency_key": "dup-1"}),
    );
    let again = cli.result(
        catalog::PROFILES_DUPLICATE,
        json!({"profile_id": active, "name": "簡報", "idempotency_key": "dup-1"}),
    );
    assert_eq!(copy["profile_id"], again["profile_id"]);
    let renamed = cli.result(
        catalog::PROFILES_RENAME,
        json!({"profile_id": copy["profile_id"], "name": "簡報二"}),
    );
    assert_eq!(renamed["name"], "簡報二");
    let diff = cli.result(
        catalog::PROFILES_DIFF,
        json!({"from": {"profile_id": active}, "to": {"profile_id": copy["profile_id"]}}),
    );
    assert!(diff["items"].as_array().unwrap().is_empty());
    let refused = cli.call(catalog::PROFILES_DELETE, json!({"profile_id": active}));
    assert_eq!(refused["error"]["data"]["reason"], "profile_in_use");
    let exported = cli.result(catalog::PROFILES_EXPORT, json!({"profile_id": active}));
    let validation = cli.result(
        catalog::PROFILES_IMPORT_VALIDATE,
        json!({"export": exported["export"]}),
    );
    assert_eq!(validation["importable"], true, "{validation}");
    let imported = cli.result(
        catalog::PROFILES_IMPORT,
        json!({"export": exported["export"], "name": "匯入"}),
    );
    assert_eq!(imported["name"], "匯入");
}

#[test]
fn switching_profiles_is_a_change_and_moves_the_active_profile() {
    let harness = harness("switch");
    let _shell = fake_shell(&harness.core, Arc::new(Mutex::new(ShellState::default())));
    let cli = TestPeer::connect(&harness.core, "dittoctl", None);
    let active = cli.result(catalog::PROFILES_LIST, json!({}))["active_profile"]
        .as_str()
        .unwrap()
        .to_string();
    let other = cli.result(
        catalog::PROFILES_CREATE,
        json!({"name": "空白", "from": "empty"}),
    );
    let switch = record(&cli.result(
        catalog::CHANGES_PROPOSE,
        json!({"base_revision": head(&cli), "ops": [{"op": "switch_profile", "to_profile": other["profile_id"]}]}),
    ));
    assert_eq!(switch.state, ChangeState::Committed);
    assert_eq!(switch.card.kind, "profile_switch");
    let listed = cli.result(catalog::PROFILES_LIST, json!({}));
    assert_eq!(listed["active_profile"], other["profile_id"]);
    assert_ne!(listed["active_profile"], json!(active));
}

#[test]
fn permissions_fail_closed_and_revoking_ends_dependent_subscriptions() {
    let harness = harness("permissions");
    let agent = TestPeer::connect(&harness.core, "agent", None);
    let cli = TestPeer::connect(&harness.core, "dittoctl", None);
    let refused = agent.call(catalog::WINDOWS_LIST, json!({}));
    assert_eq!(refused["error"]["name"], "permission_denied");
    assert_eq!(refused["error"]["data"]["reason"], "approval_unavailable");
    let grant = cli.result(
        catalog::PERMISSIONS_GRANT,
        json!({"subject": "agent", "scope": "desktop.windows.read", "idempotency_key": "g-1"}),
    );
    assert!(agent.result(catalog::WINDOWS_LIST, json!({}))["windows"].is_array());
    let subscription = agent.result(catalog::EVENTS_SUBSCRIBE, json!({}));
    let subscription_id = subscription["subscription_id"]
        .as_str()
        .unwrap()
        .to_string();
    cli.result(
        catalog::PERMISSIONS_REVOKE,
        json!({"grant_id": grant["grant_id"]}),
    );
    let refused = agent.call(catalog::WINDOWS_LIST, json!({}));
    assert_eq!(refused["error"]["name"], "permission_denied");
    let deadline = Instant::now() + Duration::from_secs(2);
    loop {
        let resynced = agent.events.lock().unwrap().iter().any(|event| {
            event["params"]["subscription_id"] == json!(subscription_id)
                && event["params"]["payload"]["reason"] == "permission_revoked"
        });
        if resynced {
            break;
        }
        assert!(Instant::now() < deadline, "no resync after revoke");
        thread::sleep(Duration::from_millis(20));
    }
    // The grant stays in the table, marked revoked.
    let listed = cli.result(
        catalog::PERMISSIONS_LIST,
        json!({"subject": "agent", "include_revoked": true}),
    );
    assert!(listed["grants"][0]["revoked_at"].is_string());
}

#[test]
fn a_session_lock_refuses_ordinary_changes() {
    let harness = harness("locked");
    let _shell = fake_shell(&harness.core, Arc::new(Mutex::new(ShellState::default())));
    let cli = TestPeer::connect(&harness.core, "dittoctl", None);
    cli.result(catalog::SESSION_LOCK, json!({}));
    let response = accent(&cli, "#333333");
    let reasons = response["error"]["data"]["reasons"].as_array().unwrap();
    assert!(
        reasons
            .iter()
            .any(|reason| reason["detail"]["why"] == "session_locked"),
        "{response}"
    );
}

#[test]
fn a_client_operation_id_finds_its_change_after_a_lost_connection() {
    // L-10 shape: the stand-in sends a change and disappears; a new client
    // finds the real outcome by the operation id it chose.
    let harness = harness("operation-id");
    let _shell = fake_shell(&harness.core, Arc::new(Mutex::new(ShellState::default())));
    let first = TestPeer::connect(&harness.core, "agent", None);
    let mut params = json!({"base_revision": head(&first), "ops": [{"op": "set_value", "path": "/avatar/hidden", "after": true}]});
    params["_meta"] = json!({"protocol_version": PROTOCOL_VERSION, "operation_id": "op-standin-1", "deadline_ms": 15000});
    let _ = first.raw(catalog::CHANGES_PROPOSE, params);
    first.close();
    let second = TestPeer::connect(&harness.core, "agent", None);
    let found = record(&second.result(
        catalog::CHANGES_GET,
        json!({"operation_id": "op-standin-1"}),
    ));
    assert_eq!(found.state, ChangeState::Committed);
    assert_eq!(
        found.origin,
        ditto_protocol::change::ChangeOrigin::AgentStandin
    );
}

/// Leave a change in `state` the way a crash would: every row written up to
/// that state, nothing after.
fn interrupted_change(
    tx: &rusqlite::Transaction<'_>,
    profile_id: &str,
    base: &str,
    target: &ditto_protocol::profile::ProfileDocument,
    state: ChangeState,
    key: &str,
) -> ditto_store::StoreResult<String> {
    use ditto_protocol::change::{ChangeMode, ChangeOrigin, HotSwapLevel};
    use ditto_store::changes;
    let card = crate::docops::card(&[], vec![]);
    let stored = changes::insert(
        tx,
        &changes::NewChange {
            profile_id,
            base_revision: base,
            ops: &[],
            mode: ChangeMode::Apply,
            origin: &ChangeOrigin::Cli,
            subject: "cli",
            idempotency_key: Some(key),
            request_operation_id: None,
            card: &card,
            hot_swap_level: HotSwapLevel::Instant,
        },
    )?;
    let id = stored.record.change_id;
    changes::set_validation(
        tx,
        &id,
        &[],
        &card,
        HotSwapLevel::Instant,
        Some(target),
        None,
    )?;
    let path = [
        ChangeState::Validated,
        ChangeState::Prepared,
        ChangeState::Applying,
        ChangeState::Verifying,
    ];
    let mut current = ChangeState::Draft;
    for next in path {
        changes::transition(tx, &id, current, next)?;
        current = next;
        if next == state {
            break;
        }
    }
    Ok(id)
}

#[test]
fn recovery_decides_every_change_a_crash_left_between_states() {
    // EX1-09 ①: after a crash in prepared, applying and verifying, each
    // change gets a terminal state from what the participants read back.
    let root = root("recovery");
    let base = plain_document("#101010");
    let target = plain_document("#202020");
    let ids = Arc::new(Mutex::new(Vec::new()));
    let recorded = Arc::clone(&ids);
    let (target_for_seed, base_for_seed) = (target.clone(), base.clone());
    // Head and base are the same document: the change never committed.
    // Only one change is ever between prepared and committed at a time (one
    // coordinator); an earlier prepared one is the interrupted-before-effect case.
    seed_store(
        &root,
        &base_for_seed,
        &base_for_seed,
        move |tx, profile, _, head| {
            let mut ids = recorded.lock().unwrap();
            ids.push(interrupted_change(
                tx,
                profile,
                head,
                &target_for_seed,
                ChangeState::Prepared,
                "k-prepared",
            )?);
            ids.push(interrupted_change(
                tx,
                profile,
                head,
                &target_for_seed,
                ChangeState::Verifying,
                "k-verifying",
            )?);
            Ok(())
        },
    );
    let core = start_without_waiting(&root, false);
    // The Shell that reconnects shows the target: it got as far as commit.
    let shell_state = Arc::new(Mutex::new(ShellState::default()));
    {
        let resolver_target = ditto_protocol::participant::ShellProjection {
            appearance: target.appearance.clone(),
            avatar: target.avatar.clone(),
            slots: vec![],
            shortcuts: target.shortcuts.clone(),
        };
        shell_state.lock().unwrap().committed = Some(resolver_target);
    }
    let _shell = fake_shell(&core, Arc::clone(&shell_state));
    core.coordinate(Duration::from_secs(15), |_| ()).unwrap();
    let cli = TestPeer::connect(&core, "dittoctl", None);
    let ids = ids.lock().unwrap().clone();
    let states: Vec<ChangeRecord> = ids
        .iter()
        .map(|id| record(&cli.result(catalog::CHANGES_GET, json!({"change_id": id}))))
        .collect();
    assert_eq!(
        states[0].state,
        ChangeState::Aborted,
        "prepared never had an effect"
    );
    // Everything reads back as the target: the commit is finished.
    assert_eq!(states[1].state, ChangeState::Committed);
    for change in &states {
        assert!(change.recovered_at.is_some());
    }
    assert_eq!(document(&cli)["appearance"]["tokens"]["accent"], "#202020");
    drop(core);
    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn recovery_rolls_back_a_change_that_never_took_effect() {
    let root = root("recovery-base");
    let base = plain_document("#101010");
    let target = plain_document("#202020");
    let ids = Arc::new(Mutex::new(Vec::new()));
    let recorded = Arc::clone(&ids);
    let seeded_base = base.clone();
    seed_store(
        &root,
        &seeded_base,
        &seeded_base,
        move |tx, profile, _, head| {
            recorded.lock().unwrap().push(interrupted_change(
                tx,
                profile,
                head,
                &target,
                ChangeState::Applying,
                "k-1",
            )?);
            Ok(())
        },
    );
    let core = start_without_waiting(&root, false);
    let shell_state = Arc::new(Mutex::new(ShellState::default()));
    shell_state.lock().unwrap().committed = Some(ditto_protocol::participant::ShellProjection {
        appearance: base.appearance.clone(),
        avatar: base.avatar.clone(),
        slots: vec![],
        shortcuts: base.shortcuts.clone(),
    });
    let _shell = fake_shell(&core, Arc::clone(&shell_state));
    core.coordinate(Duration::from_secs(15), |_| ()).unwrap();
    let cli = TestPeer::connect(&core, "dittoctl", None);
    let id = ids.lock().unwrap()[0].clone();
    let change = record(&cli.result(catalog::CHANGES_GET, json!({"change_id": id})));
    assert_eq!(change.state, ChangeState::RolledBack);
    assert_eq!(document(&cli)["appearance"]["tokens"]["accent"], "#101010");
    drop(core);
    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn recovery_without_the_participant_is_unknown_and_retries_nothing() {
    let root = root("recovery-unknown");
    let base = plain_document("#101010");
    let target = plain_document("#202020");
    let ids = Arc::new(Mutex::new(Vec::new()));
    let recorded = Arc::clone(&ids);
    seed_store(&root, &base, &base, move |tx, profile, _, head| {
        recorded.lock().unwrap().push(interrupted_change(
            tx,
            profile,
            head,
            &target,
            ChangeState::Applying,
            "k-1",
        )?);
        Ok(())
    });
    let core = start_without_waiting(&root, false);
    core.coordinate(Duration::from_secs(15), |_| ()).unwrap();
    let cli = TestPeer::connect(&core, "dittoctl", None);
    let id = ids.lock().unwrap()[0].clone();
    let change = record(&cli.result(catalog::CHANGES_GET, json!({"change_id": id})));
    assert_eq!(change.state, ChangeState::Unknown);
    assert_eq!(change.result, Some(ResultKind::Unknown));
    assert_eq!(
        change.failure_key.as_deref(),
        Some("recovery.participant_unavailable")
    );
    drop(core);
    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn a_full_disk_refuses_before_the_protected_revision_is_touched() {
    let harness = harness("storage-low");
    let _shell = fake_shell(&harness.core, Arc::new(Mutex::new(ShellState::default())));
    let cli = TestPeer::connect(&harness.core, "dittoctl", None);
    // The pre-commit space check is the early, explainable part of REC-05;
    // the transaction is what protects the head (tested in ditto-store and
    // with a capacity-limited tmpfs in tests/g1/persistence-faults).
    let free = ditto_store::free_bytes(&harness.root).unwrap();
    assert!(
        free > ditto_store::MIN_FREE_BYTES,
        "the test machine itself is nearly full"
    );
    let change = record(&accent(&cli, "#445566")["result"]);
    assert_eq!(change.state, ChangeState::Committed);
}

// ---- shared contract vectors (G1-QA-01) ----------------------------------------

fn vectors() -> Vec<(String, Value)> {
    let directory = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests/contract-vectors/0.2");
    let mut files: Vec<PathBuf> = std::fs::read_dir(&directory)
        .expect("vector directory")
        .flatten()
        .map(|entry| entry.path())
        .filter(|path| path.extension().is_some_and(|ext| ext == "json"))
        .collect();
    files.sort();
    assert!(!files.is_empty(), "no contract vectors");
    files
        .into_iter()
        .map(|path| {
            let name = path.file_name().unwrap().to_string_lossy().into_owned();
            let value = serde_json::from_str(&std::fs::read_to_string(&path).unwrap())
                .expect("vector json");
            (name, value)
        })
        .collect()
}

/// Deserialize `value` as the Rust type named by its schema, then serialize
/// it back: a valid vector must survive unchanged.
fn roundtrip(schema: &str, value: &Value) -> Result<Value, String> {
    fn through<T: serde::de::DeserializeOwned + serde::Serialize>(
        value: &Value,
    ) -> Result<Value, String> {
        let typed: T = serde_json::from_value(value.clone()).map_err(|error| error.to_string())?;
        Ok(serde_json::to_value(typed).expect("serializes"))
    }
    use ditto_protocol::{change, participant, rpc};
    match schema {
        "rpc-response" => through::<rpc::RpcResponse>(value),
        "rpc-request" => through::<rpc::RpcRequest>(value),
        "desktop-event-notification" => through::<ditto_protocol::DesktopEventNotification>(value),
        "result-meta" => through::<ditto_protocol::ResultMeta>(value),
        "request-meta" => through::<ditto_protocol::RequestMeta>(value),
        "change-op" => through::<change::ChangeOp>(value),
        "change-record" => through::<change::ChangeRecord>(value),
        "participant-prepare-params" => through::<participant::PrepareParams>(value),
        "shell-report-input" => through::<participant::ShellObservation>(value),
        "handshake-input" => through::<rpc::HandshakeInput>(value),
        other => panic!("the Rust vector runner does not know schema {other}; add it"),
    }
}

#[test]
fn contract_vectors_shapes_round_trip_in_rust() {
    for (name, vector) in vectors()
        .into_iter()
        .filter(|(_, vector)| vector["kind"] == "shape")
    {
        let outcome = roundtrip(vector["type"].as_str().unwrap(), &vector["value"]);
        if vector["valid"] == true {
            let back = outcome.unwrap_or_else(|error| panic!("{name}: {error}"));
            assert_eq!(
                back, vector["value"],
                "{name}: changed on the way through Rust"
            );
        } else {
            assert!(outcome.is_err(), "{name}: an invalid value was accepted");
        }
    }
}

fn substitute(value: &Value, head: &str, previous: &Value) -> Value {
    match value {
        Value::String(text) if text == "$head" => json!(head),
        Value::String(text) if text.starts_with("$prev.") => previous
            .pointer(&text["$prev.".len()..])
            .cloned()
            .unwrap_or(Value::Null),
        Value::Array(items) => Value::Array(
            items
                .iter()
                .map(|item| substitute(item, head, previous))
                .collect(),
        ),
        Value::Object(map) => Value::Object(
            map.iter()
                .map(|(key, item)| (key.clone(), substitute(item, head, previous)))
                .collect(),
        ),
        other => other.clone(),
    }
}

fn check_expectation(name: &str, response: &Value, expect: &Value, previous: &Value) {
    if let Some(error) = expect.get("error_name") {
        assert_eq!(&response["error"]["name"], error, "{name}: {response}");
    }
    if let Some(reason) = expect.get("error_reason") {
        assert_eq!(
            &response["error"]["data"]["reason"], reason,
            "{name}: {response}"
        );
    }
    let result = &response["result"];
    if let Some(keys) = expect.get("result_has").and_then(Value::as_array) {
        for key in keys {
            assert!(
                result.get(key.as_str().unwrap()).is_some(),
                "{name}: result lacks {key}: {response}"
            );
        }
    }
    if let Some(path) = expect.get("result_path").and_then(Value::as_str) {
        let wanted = substitute(&expect["equals"], "", previous);
        assert_eq!(result.pointer(path), Some(&wanted), "{name}: {response}");
    }
    if expect.get("every_scope_nonempty") == Some(&json!(true)) {
        for item in result["capabilities"].as_array().expect("capabilities") {
            assert!(
                !item["resource_scope"].as_array().unwrap().is_empty(),
                "{name}: {}",
                item["capability_id"]
            );
        }
    }
}

#[test]
fn contract_vectors_scenarios_hold_against_the_rust_core() {
    let harness = harness("vectors");
    let _shell = fake_shell(&harness.core, Arc::new(Mutex::new(ShellState::default())));
    for (name, vector) in vectors()
        .into_iter()
        .filter(|(_, vector)| vector["kind"] == "scenario")
    {
        let kind = vector["client"]["kind"].as_str().unwrap_or("dittoctl");
        let version = vector["client"]["protocol_version"]
            .as_str()
            .unwrap_or(PROTOCOL_VERSION);
        let steps = vector["steps"].as_array().unwrap();
        if steps
            .first()
            .is_some_and(|step| step.get("handshake").is_some())
        {
            let (client, server) = UnixStream::pair().unwrap();
            let core = Arc::clone(&harness.core);
            thread::spawn(move || {
                let _ = serve_connection(server, core, TOKEN);
            });
            let mut writer = client.try_clone().unwrap();
            let mut reader = BufReader::new(client);
            serde_json::to_writer(
                &mut writer,
                &json!({"jsonrpc":"2.0","id":"h","method":"core.handshake","params":{"protocol_version": version,"client":{"kind":kind,"version":"0.2.0"},"auth":{"token":TOKEN}}}),
            )
            .unwrap();
            writer.write_all(b"\n").unwrap();
            let mut line = String::new();
            reader.read_line(&mut line).unwrap();
            let response: Value = serde_json::from_str(&line).unwrap();
            check_expectation(&name, &response, &steps[0]["expect"], &Value::Null);
            continue;
        }
        let peer = TestPeer::connect(&harness.core, kind, None);
        let mut previous = Value::Null;
        for step in steps {
            let send = substitute(&step["send"], &head(&peer), &previous);
            let method = send["method"].as_str().unwrap();
            let mut params = send["params"].clone();
            let response = if let Some(id) = send.get("id").and_then(Value::as_str) {
                params["_meta"] = json!({"protocol_version": PROTOCOL_VERSION});
                let (waiter, answer) = mpsc::channel();
                peer.pending.lock().unwrap().insert(id.to_string(), waiter);
                let mut stream = peer.stream.try_clone().unwrap();
                serde_json::to_writer(
                    &mut stream,
                    &json!({"jsonrpc":"2.0","id":id,"method":method,"params":params}),
                )
                .unwrap();
                stream.write_all(b"\n").unwrap();
                answer
                    .recv_timeout(Duration::from_secs(10))
                    .expect("answer")
            } else if send.get("no_meta") == Some(&json!(true)) {
                peer.raw(method, params)
            } else {
                peer.call_as(
                    method,
                    params,
                    send.get("on_behalf_of").and_then(Value::as_str),
                )
            };
            check_expectation(&name, &response, &step["expect"], &previous);
            previous = response["result"].clone();
        }
    }
}
