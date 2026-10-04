//! `dittoctl`. Every command prints the structured result; write commands
//! print the change record or the readback, never just "ok".

use std::{
    env,
    io::{self, Read},
    time::{Duration, Instant},
};

use ditto_protocol::{catalog, ids};
use ditto_store::{audit, changes, profiles, rescue, Paths, Store, StoreError, WriterLock};
use dittoctl::client::{Client, Failure};
use serde_json::{json, Value};

const USAGE: &str = "usage: dittoctl [--json] <command>
  probe <handshake|capabilities|outputs|workspaces|windows|window ID ...|events --for S>
  call <capability_id> [JSON] [--operation-id ID] [--deadline MS]
  profiles list | get [ID] | create NAME [--empty] | duplicate ID NAME | rename ID NAME
           | delete ID | diff FROM TO | export ID | import-validate FILE | import FILE NAME
  changes propose FILE|- [--preview] | get ID | by-operation OP | list | cancel ID | undo ID | confirm ID
  appearance get | set KEY=VALUE...            (token.accent=#9d7bff, reduced_motion=true, locale=en)
  panels | layout | shortcuts | commands [invoke ID]
  plugins list | get ID [VERSION] | inspect PATH | install PATH [--sha256 HEX] | remove ID VERSION | diag [ENTRY]
  permissions list [SUBJECT] | check SUBJECT CAPABILITY [GRANT] | grant SUBJECT SCOPE [PATH] | revoke GRANT
  launcher search QUERY | list [CATEGORY] | launch APP_ID | open URI
  notifications list | dismiss ID | policy
  session state | lock | logout | suspend | poweroff
  jobs list | get ID | cancel ID
  tasks list | add TEXT | complete ID | watch SECONDS
  events --for SECONDS [--topics desktop,changes,plugins,notifications,tasks,session]
  rescue status | history [--limit N] | disable ENTRY|PACKAGE | restore-last-good | resume-shell | diag [--change ID]
         | restart core|hostd|shell   [--offline]";

fn usage() -> io::Error {
    io::Error::new(io::ErrorKind::InvalidInput, USAGE)
}

struct Output {
    compact: bool,
}

impl Output {
    fn print(&self, value: &Value) {
        if self.compact {
            println!("{value}");
        } else {
            println!(
                "{}",
                serde_json::to_string_pretty(value).unwrap_or_default()
            );
        }
    }

    fn failure(&self, capability: &str, failure: &Failure) -> i32 {
        let record = json!({
            "capability": capability,
            "ok": false,
            "error": {
                "name": failure.error.name,
                "code": failure.error.code,
                "message": failure.error.message,
                "outcome": failure.error.outcome,
                "data": failure.error.data,
            }
        });
        self.print(&record);
        1
    }
}

fn read_json(path: &str) -> io::Result<Value> {
    let mut text = String::new();
    if path == "-" {
        io::stdin().read_to_string(&mut text)?;
    } else {
        text = std::fs::read_to_string(path)?;
    }
    Ok(serde_json::from_str(&text)?)
}

fn flag(arguments: &mut Vec<String>, name: &str) -> bool {
    let before = arguments.len();
    arguments.retain(|argument| argument != name);
    arguments.len() != before
}

fn option(arguments: &mut Vec<String>, name: &str) -> Option<String> {
    let index = arguments.iter().position(|argument| argument == name)?;
    if index + 1 >= arguments.len() {
        return None;
    }
    let value = arguments.remove(index + 1);
    arguments.remove(index);
    Some(value)
}

fn arg(arguments: &[String], index: usize) -> io::Result<String> {
    arguments.get(index).cloned().ok_or_else(usage)
}

fn key(prefix: &str) -> String {
    format!("{prefix}-{}", ids::ulid())
}

/// Map a friendly command to `(capability, params)`.
fn translate(group: &str, rest: &mut Vec<String>) -> io::Result<(String, Value)> {
    let command = rest.first().cloned().unwrap_or_default();
    let tail: Vec<String> = rest.iter().skip(1).cloned().collect();
    let pair = |capability: &str, params: Value| Ok((capability.to_string(), params));
    match (group, command.as_str()) {
        ("profiles", "list") => pair(catalog::PROFILES_LIST, json!({})),
        ("profiles", "get") => pair(
            catalog::PROFILES_GET,
            match tail.first() {
                Some(id) => json!({ "profile_id": id }),
                None => json!({}),
            },
        ),
        ("profiles", "create") => {
            let empty = flag(rest, "--empty");
            let tail: Vec<String> = rest.iter().skip(1).cloned().collect();
            pair(
                catalog::PROFILES_CREATE,
                json!({ "name": arg(&tail, 0)?, "from": if empty { "empty" } else { "default" }, "idempotency_key": key("cli") }),
            )
        }
        ("profiles", "duplicate") => pair(
            catalog::PROFILES_DUPLICATE,
            json!({ "profile_id": arg(&tail, 0)?, "name": arg(&tail, 1)?, "idempotency_key": key("cli") }),
        ),
        ("profiles", "rename") => pair(
            catalog::PROFILES_RENAME,
            json!({ "profile_id": arg(&tail, 0)?, "name": arg(&tail, 1)? }),
        ),
        ("profiles", "delete") => pair(
            catalog::PROFILES_DELETE,
            json!({ "profile_id": arg(&tail, 0)? }),
        ),
        ("profiles", "diff") => {
            let reference = |text: String| {
                if ids::has_prefix(&text, ids::REVISION) {
                    json!({ "revision_id": text })
                } else {
                    json!({ "profile_id": text })
                }
            };
            pair(
                catalog::PROFILES_DIFF,
                json!({ "from": reference(arg(&tail, 0)?), "to": reference(arg(&tail, 1)?) }),
            )
        }
        ("profiles", "export") => pair(
            catalog::PROFILES_EXPORT,
            json!({ "profile_id": arg(&tail, 0)? }),
        ),
        ("profiles", "import-validate") => pair(
            catalog::PROFILES_IMPORT_VALIDATE,
            json!({ "export": read_json(&arg(&tail, 0)?)? }),
        ),
        ("profiles", "import") => pair(
            catalog::PROFILES_IMPORT,
            json!({ "export": read_json(&arg(&tail, 0)?)?, "name": arg(&tail, 1)?, "idempotency_key": key("cli") }),
        ),
        ("changes", "propose") => {
            let preview = flag(rest, "--preview");
            let tail: Vec<String> = rest.iter().skip(1).cloned().collect();
            let mut body = read_json(&arg(&tail, 0)?)?;
            if preview {
                body["mode"] = json!("preview");
            }
            if body.get("idempotency_key").is_none() {
                body["idempotency_key"] = json!(key("cli"));
            }
            pair(catalog::CHANGES_PROPOSE, body)
        }
        ("changes", "get") => pair(catalog::CHANGES_GET, json!({ "change_id": arg(&tail, 0)? })),
        ("changes", "by-operation") => pair(
            catalog::CHANGES_GET,
            json!({ "operation_id": arg(&tail, 0)? }),
        ),
        ("changes", "list") => pair(catalog::CHANGES_LIST, json!({})),
        ("changes", "cancel") => pair(
            catalog::CHANGES_CANCEL,
            json!({ "change_id": arg(&tail, 0)? }),
        ),
        ("changes", "undo") => pair(
            catalog::CHANGES_UNDO,
            json!({ "change_id": arg(&tail, 0)?, "idempotency_key": key("cli-undo") }),
        ),
        ("changes", "confirm") => pair(
            catalog::CHANGES_CONFIRM,
            json!({ "change_id": arg(&tail, 0)? }),
        ),
        ("appearance", "get") => pair(catalog::APPEARANCE_GET, json!({})),
        ("appearance", "set") => Err(io::Error::other(
            "appearance set needs the head revision; handled separately",
        )),
        ("commands", "invoke") => pair(
            catalog::COMMANDS_INVOKE,
            json!({ "command_id": arg(&tail, 0)? }),
        ),
        ("plugins", "list") => pair(catalog::PLUGINS_LIST, json!({})),
        ("plugins", "get") => pair(
            catalog::PLUGINS_GET,
            match tail.get(1) {
                Some(version) => json!({ "package_id": arg(&tail, 0)?, "version": version }),
                None => json!({ "package_id": arg(&tail, 0)? }),
            },
        ),
        ("plugins", "inspect") => pair(
            catalog::PLUGINS_INSPECT,
            json!({ "path": absolute(&arg(&tail, 0)?)? }),
        ),
        ("plugins", "install") => {
            let sha = option(rest, "--sha256");
            let tail: Vec<String> = rest.iter().skip(1).cloned().collect();
            let mut body = json!({ "path": absolute(&arg(&tail, 0)?)?, "idempotency_key": key("cli-install") });
            if let Some(sha) = sha {
                body["expected_sha256"] = json!(sha);
            }
            pair(catalog::PLUGINS_INSTALL, body)
        }
        ("plugins", "remove") => pair(
            catalog::PLUGINS_REMOVE,
            json!({ "package_id": arg(&tail, 0)?, "version": arg(&tail, 1)? }),
        ),
        ("plugins", "diag") => pair(
            catalog::PLUGINS_DIAGNOSTICS,
            match tail.first() {
                Some(entry) => json!({ "entry_id": entry }),
                None => json!({}),
            },
        ),
        ("permissions", "list") => pair(
            catalog::PERMISSIONS_LIST,
            match tail.first() {
                Some(subject) => json!({ "subject": subject, "include_revoked": true }),
                None => json!({ "include_revoked": true }),
            },
        ),
        ("permissions", "check") => {
            let mut body = json!({ "subject": arg(&tail, 0)?, "capability_id": arg(&tail, 1)? });
            if let Some(resource) = tail.get(2) {
                body["resource"] = json!(resource);
            }
            pair(catalog::PERMISSIONS_CHECK, body)
        }
        ("permissions", "grant") => {
            let mut body = json!({ "subject": arg(&tail, 0)?, "scope": arg(&tail, 1)?, "idempotency_key": key("cli-grant") });
            if let Some(path) = tail.get(2) {
                body["resource"] = json!(absolute(path)?);
            }
            pair(catalog::PERMISSIONS_GRANT, body)
        }
        ("permissions", "revoke") => pair(
            catalog::PERMISSIONS_REVOKE,
            json!({ "grant_id": arg(&tail, 0)? }),
        ),
        ("launcher", "search") => {
            pair(catalog::LAUNCHER_SEARCH, json!({ "query": arg(&tail, 0)? }))
        }
        ("launcher", "list") => pair(
            catalog::LAUNCHER_LIST_APPS,
            match tail.first() {
                Some(category) => json!({ "category": category }),
                None => json!({}),
            },
        ),
        ("launcher", "launch") => pair(
            catalog::LAUNCHER_LAUNCH,
            json!({ "app_id": arg(&tail, 0)? }),
        ),
        ("launcher", "open") => pair(
            catalog::LAUNCHER_LAUNCH,
            json!({ "open_uri": arg(&tail, 0)? }),
        ),
        ("notifications", "list") => pair(catalog::NOTIFICATIONS_LIST, json!({})),
        ("notifications", "dismiss") => pair(
            catalog::NOTIFICATIONS_DISMISS,
            json!({ "id": arg(&tail, 0)?.parse::<u32>().map_err(|_| usage())? }),
        ),
        ("notifications", "policy") => pair(catalog::NOTIFICATIONS_POLICY_STATUS, json!({})),
        ("notifications", "rules") => pair(catalog::NOTIFICATIONS_POLICY_GET, json!({})),
        ("session", "state") => pair(catalog::SESSION_STATE, json!({})),
        ("session", "lock") => pair(catalog::SESSION_LOCK, json!({})),
        ("session", "logout") => pair(catalog::SESSION_LOGOUT, json!({})),
        ("session", "suspend") => pair(catalog::SESSION_SUSPEND, json!({})),
        ("session", "poweroff") => pair(catalog::SESSION_POWEROFF, json!({})),
        ("jobs", "list") => pair(catalog::JOBS_LIST, json!({})),
        ("jobs", "get") => pair(catalog::JOBS_GET, json!({ "job_id": arg(&tail, 0)? })),
        ("jobs", "cancel") => pair(catalog::JOBS_CANCEL, json!({ "job_id": arg(&tail, 0)? })),
        ("tasks", "list") => pair(catalog::TASKS_LIST, json!({})),
        ("tasks", "add") => pair(catalog::TASKS_ADD, json!({ "text": tail.join(" ") })),
        ("tasks", "complete") => pair(
            catalog::TASKS_COMPLETE,
            json!({ "task_id": arg(&tail, 0)? }),
        ),
        ("rescue", "status") => pair(catalog::RESCUE_STATUS, json!({})),
        ("rescue", "resume-shell") => pair(catalog::RESCUE_RESUME_SHELL, json!({})),
        ("rescue", "disable") => pair(
            catalog::RESCUE_DISABLE,
            json!({ "target": arg(&tail, 0)?, "idempotency_key": key("rescue") }),
        ),
        ("rescue", "restore-last-good") => pair(
            catalog::RESCUE_RESTORE_LAST_GOOD,
            json!({ "idempotency_key": key("rescue") }),
        ),
        ("rescue", "history") => pair(
            catalog::CHANGES_LIST,
            json!({ "limit": option(rest, "--limit").and_then(|limit| limit.parse::<u32>().ok()).unwrap_or(20) }),
        ),
        ("panels", _) => pair(catalog::PANELS_LIST, json!({})),
        ("layout", _) => pair(catalog::LAYOUT_GET, json!({})),
        ("shortcuts", _) => pair(catalog::SHORTCUTS_LIST, json!({})),
        ("commands", _) => pair(catalog::COMMANDS_LIST, json!({})),
        _ => Err(usage()),
    }
}

fn absolute(path: &str) -> io::Result<String> {
    Ok(std::path::Path::new(path)
        .canonicalize()?
        .display()
        .to_string())
}

fn deadline_for(capability: &str) -> u64 {
    catalog::contract(capability).map_or(2_000, |contract| contract.timeout.default_ms)
}

fn online(output: &Output, group: &str, mut rest: Vec<String>, kind: &str) -> io::Result<i32> {
    let mut client = Client::connect(kind)?;
    if group == "appearance" && rest.first().map(String::as_str) == Some("set") {
        return appearance_set(output, &mut client, &rest[1..]);
    }
    if group == "rescue" && rest.first().map(String::as_str) == Some("diag") {
        let change = option(&mut rest, "--change");
        let mut report = json!({});
        for (name, capability, params) in [
            ("status", catalog::RESCUE_STATUS, json!({})),
            ("diagnostics", catalog::PLUGINS_DIAGNOSTICS, json!({})),
            (
                "recent_changes",
                catalog::CHANGES_LIST,
                json!({"limit": 20}),
            ),
        ] {
            report[name] = client
                .capability(capability, params, None, 5_000)
                .unwrap_or_else(|failure| json!({ "error": failure.error.message }));
        }
        if let Some(change) = change {
            report["change"] = client
                .capability(
                    catalog::CHANGES_GET,
                    json!({ "change_id": change }),
                    None,
                    2_000,
                )
                .unwrap_or_else(|failure| json!({ "error": failure.error.message }));
        }
        output.print(&report);
        return Ok(0);
    }
    let (capability, params) = translate(group, &mut rest)?;
    let deadline = deadline_for(&capability);
    match client.capability(&capability, params, None, deadline) {
        Ok(result) => {
            output.print(&result);
            Ok(0)
        }
        Err(failure) => Ok(output.failure(&capability, &failure)),
    }
}

/// `appearance set` reads the head first: every change names its base.
fn appearance_set(output: &Output, client: &mut Client, pairs: &[String]) -> io::Result<i32> {
    let current = client
        .capability(catalog::APPEARANCE_GET, json!({}), None, 2_000)
        .map_err(|failure| io::Error::other(failure.error.message))?;
    let mut body = json!({ "base_revision": current["profile_revision"], "idempotency_key": key("cli-appearance") });
    for pair in pairs {
        let (name, value) = pair.split_once('=').ok_or_else(usage)?;
        match name {
            token if token.starts_with("token.") => {
                if body.get("tokens").is_none() {
                    body["tokens"] = json!({});
                }
                body["tokens"][&token[6..]] = json!(value);
            }
            "reduced_motion" | "reduced_transparency" | "low_power_style" => {
                body[name] = json!(value == "true")
            }
            "theme" | "locale" => body[name] = json!(value),
            _ => return Err(usage()),
        }
    }
    match client.capability(catalog::APPEARANCE_SET, body, None, 15_000) {
        Ok(result) => {
            output.print(&result);
            Ok(0)
        }
        Err(failure) => Ok(output.failure(catalog::APPEARANCE_SET, &failure)),
    }
}

fn watch(output: &Output, seconds: u64, topics: Option<String>, tasks: bool) -> io::Result<i32> {
    let mut client = Client::connect("dittoctl")?;
    let (capability, params) = if tasks {
        (catalog::TASKS_SUBSCRIBE, json!({}))
    } else {
        let topics: Vec<String> = topics
            .map(|text| text.split(',').map(String::from).collect())
            .unwrap_or_else(|| vec!["desktop".into()]);
        (catalog::EVENTS_SUBSCRIBE, json!({ "topics": topics }))
    };
    match client.capability(capability, params, None, 5_000) {
        Ok(result) => output.print(&result),
        Err(failure) => return Ok(output.failure(capability, &failure)),
    }
    for event in std::mem::take(&mut client.events) {
        output.print(&event["params"]);
    }
    let deadline = Instant::now() + Duration::from_secs(seconds);
    client.set_read_timeout(Some(Duration::from_millis(250)))?;
    while Instant::now() < deadline {
        match client.read_message() {
            Ok(message) if message["method"] == "desktop.events" => {
                output.print(&message["params"])
            }
            Ok(_) => {}
            Err(error)
                if matches!(
                    error.kind(),
                    io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut
                ) => {}
            Err(error) => return Err(error),
        }
    }
    Ok(0)
}

fn probe(output: &Output, rest: &[String]) -> io::Result<i32> {
    let mut client = Client::connect("dittoctl")?;
    let report = |client: &mut Client, capability: &str, params: Value| -> i32 {
        let requested = params.clone();
        match client.capability(capability, params, None, 2_000) {
            Ok(result) => {
                output.print(&json!({
                    "capability": capability,
                    "request": requested,
                    "ok": true,
                    "readback_verified": result["_meta"]["readback_verified"].as_bool().unwrap_or(false),
                    "result": result,
                }));
                0
            }
            Err(failure) => {
                output.print(&json!({
                    "capability": capability,
                    "request": requested,
                    "ok": false,
                    "readback_verified": false,
                    "error": {"name": failure.error.name, "code": failure.error.code, "message": failure.error.message, "outcome": failure.error.outcome},
                }));
                1
            }
        }
    };
    let command = rest.first().map(String::as_str).ok_or_else(usage)?;
    let status = match command {
        "handshake" => {
            output.print(&client.handshake);
            0
        }
        "capabilities" => report(&mut client, catalog::CAPABILITIES_LIST, json!({})),
        "outputs" => report(&mut client, catalog::OUTPUTS_LIST, json!({})),
        "windows" => report(&mut client, catalog::WINDOWS_LIST, json!({})),
        "workspaces" => match rest.get(1).map(String::as_str) {
            None => report(&mut client, catalog::WORKSPACES_LIST, json!({})),
            Some("--activate") => report(
                &mut client,
                catalog::WORKSPACES_ACTIVATE,
                json!({ "workspace_id": arg(rest, 2)? }),
            ),
            Some("--get") => report(
                &mut client,
                catalog::WORKSPACES_GET,
                json!({ "workspace_id": arg(rest, 2)? }),
            ),
            _ => return Err(usage()),
        },
        "window" => {
            let window_id = arg(rest, 1)?;
            if rest.len() == 2 {
                report(
                    &mut client,
                    catalog::WINDOWS_GET,
                    json!({ "window_id": window_id }),
                )
            } else {
                let number = |index: usize| -> io::Result<i64> {
                    arg(rest, index)?.parse().map_err(|_| usage())
                };
                let (capability, params) = match rest[2].as_str() {
                    "--focus" => (catalog::WINDOWS_FOCUS, json!({ "window_id": window_id })),
                    "--close" => (
                        catalog::WINDOWS_CLOSE_REQUEST,
                        json!({ "window_id": window_id }),
                    ),
                    "--move" => (
                        catalog::WINDOWS_MOVE,
                        json!({ "window_id": window_id, "x": number(3)?, "y": number(4)? }),
                    ),
                    "--resize" => (
                        catalog::WINDOWS_RESIZE,
                        json!({ "window_id": window_id, "width": number(3)?, "height": number(4)? }),
                    ),
                    "--state" => (
                        catalog::WINDOWS_SET_STATE,
                        json!({ "window_id": window_id, "state": arg(rest, 3)? }),
                    ),
                    _ => return Err(usage()),
                };
                let status = report(&mut client, capability, params);
                // Write commands always show the state afterwards, even when
                // the capability itself cannot claim success.
                report(
                    &mut client,
                    catalog::WINDOWS_GET,
                    json!({ "window_id": window_id }),
                );
                status
            }
        }
        "events" => {
            drop(client);
            let seconds = match (rest.get(1).map(String::as_str), rest.get(2)) {
                (Some("--for"), Some(value)) => {
                    value.trim_end_matches('s').parse().map_err(|_| usage())?
                }
                _ => return Err(usage()),
            };
            return watch(output, seconds, None, false);
        }
        _ => return Err(usage()),
    };
    Ok(status)
}

// ---- offline rescue ----------------------------------------------------------

fn offline(output: &Output, rest: &[String]) -> io::Result<i32> {
    let paths = Paths::from_environment().map_err(|error| io::Error::other(error.to_string()))?;
    let command = rest.first().map(String::as_str).ok_or_else(usage)?;
    let store_error = |error: StoreError| io::Error::other(error.to_string());
    match command {
        "status" | "history" | "diag" => {
            let store = Store::open_reader(&paths).map_err(store_error)?;
            let connection = store.connection();
            let active = profiles::active_profile(connection).map_err(store_error)?;
            let profile = active
                .as_ref()
                .map(|id| profiles::get(connection, id))
                .transpose()
                .map_err(store_error)?;
            let recent = changes::list(connection, None, None, 20).map_err(store_error)?;
            let in_flight = changes::in_flight(connection).map_err(store_error)?;
            let mut report = json!({
                "mode": "offline",
                "core_running": WriterLock::acquire(&paths.lock()).is_err(),
                "active_profile": profile,
                "history": recent.iter().map(|stored| stored.record.summary()).collect::<Vec<_>>(),
                "unfinished_changes": in_flight.iter().map(|stored| json!({"change_id": stored.record.change_id, "state": stored.record.state})).collect::<Vec<_>>(),
            });
            if command == "diag" {
                report["audit"] = json!(audit::recent(connection, None, 50)
                    .map_err(store_error)?
                    .into_iter()
                    .map(|row| json!({"ts": row.ts, "change_id": row.change_id, "subject": row.subject, "action": row.action, "decision": row.decision, "detail": row.redacted_detail}))
                    .collect::<Vec<_>>());
            }
            output.print(&report);
            Ok(0)
        }
        "restore-last-good" | "disable" => {
            let lock = match WriterLock::acquire(&paths.lock()) {
                Ok(lock) => lock,
                Err(StoreError::Locked) => {
                    eprintln!("Core is running and holds the store; run this rescue command without --offline");
                    return Ok(1);
                }
                Err(error) => return Err(store_error(error)),
            };
            let (mut store, _) = Store::open_writer(&paths, &lock).map_err(store_error)?;
            let revision = if command == "disable" {
                let target = arg(rest, 1)?;
                store
                    .write(|tx| rescue::disable_offline(tx, None, &target, "cli:rescue"))
                    .map_err(store_error)?
            } else {
                store
                    .write(|tx| rescue::restore_last_good_offline(tx, None, "cli:rescue"))
                    .map_err(store_error)?
            };
            output.print(&json!({
                "applied_offline": true,
                "revision": revision,
                "note": "no participant ran; Core mounts this revision at its next start and reads back what it gets",
            }));
            Ok(0)
        }
        "restart" => restart(output, &arg(rest, 1)?),
        _ => Err(usage()),
    }
}

fn restart(output: &Output, what: &str) -> io::Result<i32> {
    let (verb, unit) = match what {
        "core" => ("restart", "ditto-core.service"),
        // Core supervises both and starts them again; stopping the scope is
        // the restart. Scopes are `ditto-<launch kind>.scope`, and the
        // Shell's launch kind is `quickshell` (packaging/systemd/user).
        "hostd" => ("stop", "ditto-hostd.scope"),
        "shell" => ("stop", "ditto-quickshell.scope"),
        _ => return Err(usage()),
    };
    let status = std::process::Command::new("systemctl")
        .args(["--user", verb, unit])
        .status()?;
    output.print(&json!({ "unit": unit, "action": verb, "succeeded": status.success() }));
    Ok(if status.success() { 0 } else { 1 })
}

fn main() {
    let status = run().unwrap_or_else(|error| {
        if error.kind() == io::ErrorKind::InvalidInput {
            eprintln!("{error}");
            2
        } else {
            eprintln!("dittoctl: {error}");
            1
        }
    });
    std::process::exit(status);
}

/// `call` prints the bare result; `probe call` prints the same record as the
/// other probe commands (`capability`, `request`, `ok`, `readback_verified`,
/// `result`), which is what the verification scripts parse.
fn run_call(output: &Output, mut rest: Vec<String>, as_probe: bool) -> io::Result<i32> {
    let operation_id = option(&mut rest, "--operation-id");
    let deadline = option(&mut rest, "--deadline").and_then(|value| value.parse().ok());
    let capability = arg(&rest, 0)?;
    let params = match rest.get(1) {
        Some(text) if text == "-" => read_json("-")?,
        Some(text) => serde_json::from_str(text)?,
        None => json!({}),
    };
    let kind = if capability.starts_with("desktop.rescue.") {
        "dittoctl-rescue"
    } else {
        "dittoctl"
    };
    let requested = params.clone();
    let mut client = Client::connect(kind)?;
    match client.capability(
        &capability,
        params,
        operation_id.as_deref(),
        deadline.unwrap_or_else(|| deadline_for(&capability)),
    ) {
        Ok(result) if as_probe => {
            output.print(&json!({
                "capability": capability,
                "request": requested,
                "ok": true,
                "readback_verified": result["_meta"]["readback_verified"].as_bool().unwrap_or(false),
                "result": result,
            }));
            Ok(0)
        }
        Ok(result) => {
            output.print(&result);
            Ok(0)
        }
        Err(failure) => Ok(output.failure(&capability, &failure)),
    }
}

fn run() -> io::Result<i32> {
    let mut arguments: Vec<String> = env::args().skip(1).collect();
    let output = Output {
        compact: flag(&mut arguments, "--json"),
    };
    let offline_mode = flag(&mut arguments, "--offline");
    let Some(group) = arguments.first().cloned() else {
        return Err(usage());
    };
    let mut rest: Vec<String> = arguments[1..].to_vec();
    // `probe call` is the same generic call, under the diagnostics name the
    // verification scripts use.
    if group == "probe" && rest.first().map(String::as_str) == Some("call") {
        rest.remove(0);
        return run_call(&output, rest, true);
    }
    match group.as_str() {
        "probe" => probe(&output, &rest),
        "call" => run_call(&output, rest, false),
        "events" => {
            let seconds = option(&mut rest, "--for")
                .and_then(|value| value.trim_end_matches('s').parse().ok())
                .ok_or_else(usage)?;
            watch(&output, seconds, option(&mut rest, "--topics"), false)
        }
        "tasks" if rest.first().map(String::as_str) == Some("watch") => {
            let seconds = arg(&rest, 1)?.parse().map_err(|_| usage())?;
            watch(&output, seconds, None, true)
        }
        "rescue" if offline_mode => offline(&output, &rest),
        "rescue" if rest.first().map(String::as_str) == Some("restart") => {
            restart(&output, &arg(&rest, 1)?)
        }
        "rescue" => online(&output, "rescue", rest, "dittoctl-rescue"),
        "panels" | "layout" | "shortcuts" => {
            online(&output, &group, vec![String::new()], "dittoctl")
        }
        _ => online(&output, &group, rest, "dittoctl"),
    }
}
