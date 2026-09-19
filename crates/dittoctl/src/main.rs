//! `dittoctl probe`: G0 diagnostics and the second consumer of every capability,
//! so the contract can be exercised without a graphical session. Write commands
//! always print the readback comparison. This is not a rescue CLI: it needs a
//! running Core, and rescue mode is not part of G0.

use std::{
    env,
    io::{self, BufRead, BufReader, Write},
    os::unix::{io::FromRawFd, io::RawFd, net::UnixStream},
    path::PathBuf,
    time::{Duration, Instant},
};

use ditto_protocol::{
    catalog,
    rpc::{ClientInfo, HandshakeAuth, HandshakeInput, RpcError, RpcRequest, RpcResponse},
    RequestMeta, LAUNCHER_KIND_ENV, LAUNCHER_SOCKET_ENV, LAUNCHER_TOKEN_FD_ENV,
    LAUNCHER_VERSION_ENV, PROTOCOL_VERSION,
};
use serde_json::{json, Value};

const USAGE: &str = "usage: dittoctl probe <command> [--json]\n\
  handshake                    negotiate and print the server and catalog revision\n\
  capabilities                 list the catalog with availability and claimability\n\
  outputs                      list outputs\n\
  workspaces [--activate ID]   list workspaces, or switch and read back\n\
  windows                      list windows\n\
  window ID --focus|--move X Y|--resize W H|--state STATE|--close\n\
  events --for SECONDS         subscribe, print the snapshot sequence and events\n\
G0 diagnostics only; this is not a rescue CLI and it needs a running Core.";

/// The token comes from the descriptor the launcher left open, or, in
/// development mode only, from the shared token that mode announces.
fn launcher_token() -> io::Result<String> {
    if let Ok(descriptor) = env::var(LAUNCHER_TOKEN_FD_ENV) {
        let descriptor: RawFd = descriptor
            .parse()
            .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "invalid token descriptor"))?;
        // SAFETY: the descriptor was inherited from the launcher and is used
        // once, here, for the lifetime of this process.
        let channel = unsafe { UnixStream::from_raw_fd(descriptor) };
        let mut line = String::new();
        BufReader::new(channel).read_line(&mut line)?;
        let token = line.trim().to_string();
        if token.is_empty() {
            return Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                "the launcher closed the token channel",
            ));
        }
        return Ok(token);
    }
    env::var("DITTO_DEV_TOKEN").map_err(|_| {
        io::Error::new(
            io::ErrorKind::PermissionDenied,
            "no launcher token: start this client from Core, or use development mode",
        )
    })
}

struct Probe {
    stream: UnixStream,
    reader: BufReader<UnixStream>,
    next_id: u64,
    json: bool,
}

struct Failure {
    error: RpcError,
}

impl Probe {
    fn connect(json: bool) -> io::Result<(Self, Value)> {
        let socket = match env::var_os(LAUNCHER_SOCKET_ENV) {
            Some(path) => PathBuf::from(path),
            None => PathBuf::from(env::var_os("XDG_RUNTIME_DIR").ok_or_else(|| {
                io::Error::new(io::ErrorKind::NotFound, "XDG_RUNTIME_DIR is required")
            })?)
            .join("ditto/core.sock"),
        };
        let token = launcher_token()?;
        let stream = UnixStream::connect(&socket)?;
        let reader = BufReader::new(stream.try_clone()?);
        let mut probe = Self {
            stream,
            reader,
            next_id: 0,
            json,
        };
        let handshake = probe
            .request(
                "core.handshake",
                json!(HandshakeInput {
                    protocol_version: PROTOCOL_VERSION.into(),
                    client: ClientInfo {
                        kind: env::var(LAUNCHER_KIND_ENV).unwrap_or_else(|_| "dittoctl".into()),
                        version: env::var(LAUNCHER_VERSION_ENV)
                            .unwrap_or_else(|_| env!("CARGO_PKG_VERSION").into()),
                    },
                    auth: HandshakeAuth { token },
                }),
            )
            .map_err(|failure| {
                io::Error::other(format!(
                    "handshake rejected: {} ({})",
                    failure.error.message, failure.error.code
                ))
            })?;
        Ok((probe, handshake))
    }

    fn send(&mut self, message: &Value) -> io::Result<()> {
        serde_json::to_writer(&mut self.stream, message)?;
        self.stream.write_all(b"\n")
    }

    fn read_message(&mut self) -> io::Result<Value> {
        let mut line = String::new();
        if self.reader.read_line(&mut line)? == 0 {
            return Err(io::Error::new(
                io::ErrorKind::UnexpectedEof,
                "core closed the connection",
            ));
        }
        Ok(serde_json::from_str(&line)?)
    }

    fn request(&mut self, method: &str, params: Value) -> Result<Value, Failure> {
        self.next_id += 1;
        let id = format!("{method}-{}", self.next_id);
        let body = RpcRequest {
            jsonrpc: "2.0".into(),
            id: Some(id.clone()),
            method: method.into(),
            params,
        };
        let sent = self.send(&json!(body)).and_then(|()| loop {
            let message = self.read_message()?;
            if message.get("id").and_then(Value::as_str) == Some(id.as_str()) {
                return Ok(message);
            }
        });
        let message = sent.map_err(|error| Failure {
            error: RpcError {
                code: -32099,
                name: ditto_protocol::ErrorName::Internal,
                message: error.to_string(),
                outcome: None,
            },
        })?;
        let response: RpcResponse = serde_json::from_value(message).map_err(|error| Failure {
            error: RpcError {
                code: -32099,
                name: ditto_protocol::ErrorName::Internal,
                message: format!("malformed response: {error}"),
                outcome: None,
            },
        })?;
        match (response.result, response.error) {
            (Some(result), _) => Ok(result),
            (None, Some(error)) => Err(Failure { error }),
            (None, None) => Err(Failure {
                error: RpcError {
                    code: -32099,
                    name: ditto_protocol::ErrorName::Internal,
                    message: "response carried neither result nor error".into(),
                    outcome: None,
                },
            }),
        }
    }

    fn capability(&mut self, capability_id: &str, mut params: Value) -> Result<Value, Failure> {
        if params.is_null() {
            params = json!({});
        }
        params["_meta"] = json!(RequestMeta {
            protocol_version: PROTOCOL_VERSION.into(),
            operation_id: None,
            deadline_ms: Some(2_000),
        });
        self.request(capability_id, params)
    }

    /// One matrix cell: what was asked, what came back, and whether the result
    /// was confirmed by reading the state back.
    fn report(&mut self, capability_id: &str, params: Value) -> io::Result<bool> {
        let requested = params.clone();
        let outcome = self.capability(capability_id, params);
        let record = match &outcome {
            Ok(result) => json!({
                "capability": capability_id,
                "request": requested,
                "ok": true,
                "readback_verified": result["_meta"]["readback_verified"].as_bool().unwrap_or(false),
                "result": result,
            }),
            Err(failure) => json!({
                "capability": capability_id,
                "request": requested,
                "ok": false,
                "readback_verified": false,
                "error": {
                    "name": failure.error.name,
                    "code": failure.error.code,
                    "message": failure.error.message,
                    "outcome": failure.error.outcome,
                },
            }),
        };
        if self.json {
            println!("{}", serde_json::to_string(&record)?);
        } else {
            match &outcome {
                Ok(result) => println!(
                    "{capability_id}: ok (readback_verified={})\n{}",
                    record["readback_verified"],
                    serde_json::to_string_pretty(result)?
                ),
                Err(failure) => println!(
                    "{capability_id}: {} ({}) {}",
                    serde_json::to_string(&failure.error.name)?,
                    failure.error.code,
                    failure.error.message
                ),
            }
        }
        Ok(outcome.is_ok())
    }

    fn watch_events(&mut self, seconds: u64) -> io::Result<()> {
        let subscribed = self.report(catalog::EVENTS_SUBSCRIBE, json!({}))?;
        if !subscribed {
            return Ok(());
        }
        let deadline = Instant::now() + Duration::from_secs(seconds);
        self.stream
            .set_read_timeout(Some(Duration::from_millis(250)))?;
        while Instant::now() < deadline {
            match self.read_message() {
                Ok(message) if message["method"] == "desktop.events" => {
                    if self.json {
                        println!("{}", serde_json::to_string(&message["params"])?);
                    } else {
                        println!(
                            "event seq={} {}",
                            message["params"]["seq"], message["params"]["payload"]["type"]
                        );
                    }
                }
                Ok(_) => continue,
                Err(error)
                    if matches!(
                        error.kind(),
                        io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut
                    ) =>
                {
                    continue
                }
                Err(error) => return Err(error),
            }
        }
        Ok(())
    }
}

fn window_operation(arguments: &[String]) -> io::Result<(&'static str, Value)> {
    let window_id = arguments.first().ok_or_else(usage_error)?.clone();
    match arguments.get(1).map(String::as_str) {
        Some("--focus") => Ok((catalog::WINDOWS_FOCUS, json!({ "window_id": window_id }))),
        Some("--close") => Ok((
            catalog::WINDOWS_CLOSE_REQUEST,
            json!({ "window_id": window_id }),
        )),
        Some("--move") => {
            let x: i32 = arguments
                .get(2)
                .ok_or_else(usage_error)?
                .parse()
                .map_err(|_| usage_error())?;
            let y: i32 = arguments
                .get(3)
                .ok_or_else(usage_error)?
                .parse()
                .map_err(|_| usage_error())?;
            Ok((
                catalog::WINDOWS_MOVE,
                json!({"window_id": window_id, "x": x, "y": y}),
            ))
        }
        Some("--resize") => {
            let width: u32 = arguments
                .get(2)
                .ok_or_else(usage_error)?
                .parse()
                .map_err(|_| usage_error())?;
            let height: u32 = arguments
                .get(3)
                .ok_or_else(usage_error)?
                .parse()
                .map_err(|_| usage_error())?;
            Ok((
                catalog::WINDOWS_RESIZE,
                json!({"window_id": window_id, "width": width, "height": height}),
            ))
        }
        Some("--state") => {
            let state = arguments.get(2).ok_or_else(usage_error)?;
            Ok((
                catalog::WINDOWS_SET_STATE,
                json!({"window_id": window_id, "state": state}),
            ))
        }
        _ => Err(usage_error()),
    }
}

fn usage_error() -> io::Error {
    io::Error::new(io::ErrorKind::InvalidInput, USAGE)
}

fn main() -> io::Result<()> {
    let mut arguments: Vec<String> = env::args().skip(1).collect();
    let json = arguments.iter().any(|argument| argument == "--json");
    arguments.retain(|argument| argument != "--json");
    if arguments.first().map(String::as_str) != Some("probe") || arguments.len() < 2 {
        eprintln!("{USAGE}");
        std::process::exit(2);
    }
    let command = arguments[1].clone();
    let rest = arguments[2..].to_vec();
    let (mut probe, handshake) = Probe::connect(json)?;
    match command.as_str() {
        "handshake" => println!("{}", serde_json::to_string_pretty(&handshake)?),
        "capabilities" => {
            probe.report(catalog::CAPABILITIES_LIST, json!({}))?;
        }
        "outputs" => {
            probe.report(catalog::OUTPUTS_LIST, json!({}))?;
        }
        "windows" => {
            probe.report(catalog::WINDOWS_LIST, json!({}))?;
        }
        "workspaces" => match rest.first().map(String::as_str) {
            None => {
                probe.report(catalog::WORKSPACES_LIST, json!({}))?;
            }
            Some("--activate") => {
                let workspace_id = rest.get(1).ok_or_else(usage_error)?;
                probe.report(
                    catalog::WORKSPACES_ACTIVATE,
                    json!({ "workspace_id": workspace_id }),
                )?;
            }
            Some("--get") => {
                let workspace_id = rest.get(1).ok_or_else(usage_error)?;
                probe.report(
                    catalog::WORKSPACES_GET,
                    json!({ "workspace_id": workspace_id }),
                )?;
            }
            _ => return Err(usage_error()),
        },
        "window" => {
            if rest.len() == 1 {
                probe.report(catalog::WINDOWS_GET, json!({ "window_id": rest[0] }))?;
            } else {
                let (capability_id, params) = window_operation(&rest)?;
                probe.report(capability_id, params)?;
                // Write commands always show the state afterwards, even when the
                // capability itself cannot claim success.
                probe.report(catalog::WINDOWS_GET, json!({ "window_id": rest[0] }))?;
            }
        }
        "events" => {
            let seconds = match (rest.first().map(String::as_str), rest.get(1)) {
                (Some("--for"), Some(value)) => value
                    .trim_end_matches('s')
                    .parse()
                    .map_err(|_| usage_error())?,
                _ => return Err(usage_error()),
            };
            probe.watch_events(seconds)?;
        }
        _ => {
            eprintln!("{USAGE}");
            std::process::exit(2);
        }
    }
    Ok(())
}
