//! Ditto Core: the one authority for configuration revisions, permission
//! grants and capability bindings. This module is the IPC surface —
//! newline-framed JSON-RPC over a Unix socket, protocol 0.2 — with requests in
//! both directions: clients call `desktop.*` capabilities, Core calls its
//! transaction participants (`participant.*`) and hostd (`host.invoke`).

pub mod agent_backend;
pub mod agent_manager;
pub mod agent_routes;
pub mod authz;
pub mod context;
pub mod coordinator;
pub mod core;
pub mod defaults;
pub mod desktop;
pub mod diagnostics;
pub mod docops;
pub mod error;
pub mod events;
pub mod exports;
pub mod fault;
pub mod generation;
pub mod hosts;
pub mod identity;
pub mod jobs_pool;
pub mod launcher;
pub mod log;
pub mod outputs;
pub mod participants;
pub mod peers;
pub mod preflight;
pub mod projection;
pub mod router;
pub mod sdnotify;
pub mod session;
pub mod shell;

use std::{
    collections::HashMap,
    io::{self, BufRead, BufReader, Write},
    os::fd::AsRawFd,
    os::unix::{fs::PermissionsExt, net::UnixStream},
    sync::{
        atomic::{AtomicBool, Ordering},
        mpsc::{self, Sender},
        Arc, Mutex,
    },
    thread,
    time::{Duration, Instant},
};

use ditto_protocol::{
    catalog,
    host::{
        self as host_protocol, EntryStateInput, EventInput, HelloInput, RegisterInput, RenewInput,
        ResourcesInput, RevokeInput,
    },
    participant::{ShellObservation, SHELL_REPORT},
    rpc::{HandshakeInput, HandshakeOutput, RpcRequest, RpcResponse},
    ErrorName, RequestMeta, ResultMeta, Subject, PROTOCOL_VERSION,
};
use identity::IdentityRegistry;
use serde_json::{json, Map, Value};
use session::Outgoing;

use crate::{
    core::Core,
    error::CoreError,
    hosts::HostError,
    peers::{Peer, CORE_ID_PREFIX},
    router::{Call, Caller},
};

pub const MAX_LINE_BYTES: usize = 1_048_576;
pub const CANCEL_METHOD: &str = "$/cancel";

/// Capabilities with a handler in this build; the catalog consistency gate
/// checks this list against the exported catalog.
pub fn handlers() -> Vec<&'static str> {
    router::handlers()
}

fn read_line_limited<R: BufRead>(reader: &mut R) -> io::Result<Option<Vec<u8>>> {
    let mut line = Vec::new();
    loop {
        let available = reader.fill_buf()?;
        if available.is_empty() {
            if line.is_empty() {
                return Ok(None);
            }
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "unterminated JSON line",
            ));
        }
        let count = available
            .iter()
            .position(|byte| *byte == b'\n')
            .map_or(available.len(), |index| index + 1);
        if line.len() + count > MAX_LINE_BYTES {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "JSON line exceeds 1 MiB",
            ));
        }
        let found_newline = available[count - 1] == b'\n';
        line.extend_from_slice(&available[..count]);
        reader.consume(count);
        if found_newline {
            return Ok(Some(line));
        }
    }
}

fn peer_credentials(stream: &UnixStream) -> io::Result<libc::ucred> {
    let mut credentials = libc::ucred {
        pid: 0,
        uid: 0,
        gid: 0,
    };
    let mut length = std::mem::size_of::<libc::ucred>() as libc::socklen_t;
    // SAFETY: credentials is a valid writable ucred and length is its size.
    let result = unsafe {
        libc::getsockopt(
            stream.as_raw_fd(),
            libc::SOL_SOCKET,
            libc::SO_PEERCRED,
            (&mut credentials as *mut libc::ucred).cast(),
            &mut length,
        )
    };
    if result != 0 {
        return Err(io::Error::last_os_error());
    }
    if length as usize != std::mem::size_of::<libc::ucred>() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "invalid peer credentials",
        ));
    }
    Ok(credentials)
}

fn reject(id: String, name: ErrorName, message: &str) -> RpcResponse {
    RpcResponse::error(id, name, message)
}

pub enum AuthMode<'a> {
    DevelopmentToken(&'a str),
    LauncherRegistry(&'a IdentityRegistry),
}

/// The authorization subject a client kind is bound to. A kind that is not
/// listed gets no subject and is refused at the handshake.
pub fn subject_for_kind(kind: &str) -> Option<Subject> {
    Some(Subject(
        match kind {
            "quickshell" => Subject::SHELL,
            "dittoctl" => Subject::CLI,
            "dittoctl-rescue" => Subject::CLI_RESCUE,
            "rescue-shell" => Subject::RESCUE_UI,
            "agent" => Subject::AGENT,
            "lock" => Subject::LOCK,
            "hostd" => "hostd",
            _ => return None,
        }
        .into(),
    ))
}

/// One in-flight request. Cancellation is refused, never faked: a capability
/// declared non-cancellable reports the refusal on its own response.
struct RequestControl {
    cancellable: bool,
    cancelled: AtomicBool,
    refused_cancel: AtomicBool,
}

type InFlight = Arc<Mutex<HashMap<String, Arc<RequestControl>>>>;

struct Connection {
    connection_id: String,
    kind: String,
    subject: Subject,
    peer: Arc<Peer>,
    host_generation: Option<u64>,
    /// Set once the connection has ended (read by queued proposals).
    gone: Arc<AtomicBool>,
}

// An error here is a complete JSON-RPC response sent once per connection;
// boxing it would only move the same allocation.
#[allow(clippy::result_large_err)]
fn handshake(
    core: &Arc<Core>,
    request: RpcRequest,
    auth_mode: &AuthMode<'_>,
    peer: libc::ucred,
    sink: &Sender<Outgoing>,
) -> Result<(RpcResponse, Connection), RpcResponse> {
    let id = request.id.clone().unwrap_or_else(|| "handshake".into());
    if request.method != "core.handshake" {
        return Err(reject(
            id,
            ErrorName::IdentityRejected,
            "handshake required",
        ));
    }
    let Ok(input) = serde_json::from_value::<HandshakeInput>(request.params) else {
        return Err(reject(id, ErrorName::InvalidParams, "invalid handshake"));
    };
    if input.protocol_version != PROTOCOL_VERSION {
        return Err(reject(
            id,
            ErrorName::ProtocolVersionUnsupported,
            "protocol version unsupported",
        ));
    }
    let accepted = match auth_mode {
        // Development mode has one shared token and takes the client's word
        // for its kind. It is not identity evidence: EX-07 is decided on the
        // launcher path below.
        AuthMode::DevelopmentToken(expected) => input.auth.token == *expected,
        AuthMode::LauncherRegistry(registry) => registry
            .verify_once(
                &input.auth.token,
                peer.uid,
                peer.pid as u32,
                &input.client.kind,
                &input.client.version,
            )
            .is_ok(),
    };
    let Some(subject) = subject_for_kind(&input.client.kind).filter(|_| accepted) else {
        // Diagnostic only: which kind and PID were refused, never the token.
        crate::log::event(
            "connection.identity_rejected",
            &[
                ("kind", crate::log::connection_kind(&input.client.kind)),
                ("pid", &peer.pid.to_string()),
                (
                    "reason_code",
                    if accepted {
                        "unknown_kind"
                    } else {
                        "binding_mismatch"
                    },
                ),
            ],
        );
        return Err(reject(id, ErrorName::IdentityRejected, "identity rejected"));
    };
    let connection_id = core.next_connection_id();
    let peer = Arc::new(Peer::new(
        connection_id.clone(),
        input.client.kind.clone(),
        peer.pid as u32,
        sink.clone(),
    ));
    let host_generation = match input.client.kind.as_str() {
        "hostd" => Some(core.hosts.attach(Arc::clone(&peer))),
        "agent" => {
            let managed = core.agent.attach(Arc::clone(&peer));
            // Production never falls back to G1's uncorrelated stand-in.
            // Development sockets and explicit fault builds remain fixtures,
            // and are not evidence of bound production Agent authority.
            if !managed
                && matches!(auth_mode, AuthMode::LauncherRegistry(_))
                && !cfg!(feature = "fault-injection")
            {
                return Err(reject(
                    id,
                    ErrorName::IdentityRejected,
                    "Agent must be started by the dedicated Core supervisor",
                ));
            }
            None
        }
        "quickshell" => {
            core.shell.attach(Arc::clone(&peer));
            // A (re)connected Shell mounts what is committed, never a half
            // change: the coordinator pushes the head's projection to it.
            core.submit(|coordinator| {
                coordinator.sync_participant(ditto_protocol::participant::ParticipantRole::Shell)
            });
            None
        }
        _ => None,
    };
    let output = HandshakeOutput {
        protocol_version: PROTOCOL_VERSION.into(),
        catalog_revision: catalog::CATALOG_REVISION,
        server: match auth_mode {
            AuthMode::DevelopmentToken(_) => "ditto-core/g1-development",
            AuthMode::LauncherRegistry(_) => "ditto-core/g1-bound",
        }
        .into(),
        compositor: Some(core.session.compositor_label()),
        mode: core.mode,
        subject: subject.0.clone(),
        connection_id: connection_id.clone(),
        host_generation,
    };
    Ok((
        RpcResponse::ok(id, json!(output)),
        Connection {
            connection_id,
            kind: input.client.kind,
            subject,
            peer,
            host_generation,
            gone: Arc::new(AtomicBool::new(false)),
        },
    ))
}

fn host_error(id: String, error: HostError) -> RpcResponse {
    let error = match error {
        HostError::Identity => {
            CoreError::identity("this entry is not assigned to this host connection")
        }
        HostError::Conflict(reason) => CoreError::conflict(reason, "refused"),
        HostError::Invalid(message) => CoreError::invalid(message),
        HostError::Unavailable(reason) => CoreError::unavailable(reason, "unavailable"),
    };
    error.response(id)
}

fn parse<T: serde::de::DeserializeOwned>(params: &Map<String, Value>) -> Result<T, CoreError> {
    serde_json::from_value(Value::Object(params.clone()))
        .map_err(|error| CoreError::invalid(format!("invalid parameters: {error}")))
}

/// Control methods are answered in order on the reader thread: registration
/// and revocation must not overtake each other (host protocol §5).
#[allow(clippy::result_large_err)]
fn control(
    core: &Arc<Core>,
    connection: &Connection,
    id: String,
    method: &str,
    mut params: Map<String, Value>,
) -> RpcResponse {
    if method == SHELL_REPORT {
        if connection.kind != "quickshell" {
            return reject(
                id,
                ErrorName::IdentityRejected,
                "only the Shell reports mounts",
            );
        }
        params.remove("_meta");
        return match parse::<ShellObservation>(&params) {
            Ok(observation) => {
                core.shell.report(observation);
                if let Ok(panels) = router::panels(core) {
                    core.publish(ditto_protocol::DesktopEventPayload::PanelsChanged {
                        panels: panels.panels,
                    });
                }
                RpcResponse::ok(id, json!({}))
            }
            Err(error) => error.response(id),
        };
    }
    let Some(generation) = connection
        .host_generation
        .filter(|_| connection.kind == "hostd")
    else {
        return reject(
            id,
            ErrorName::IdentityRejected,
            "host methods need a hostd connection",
        );
    };
    let meta = params
        .remove("_meta")
        .and_then(|meta| serde_json::from_value::<RequestMeta>(meta).ok());
    let entry = meta.and_then(|meta| meta.on_behalf_of);
    let needs_entry = !host_protocol::PROCESS_METHODS.contains(&method);
    let entry_id = match (&entry, needs_entry) {
        (Some(entry), true) => {
            if !core.hosts.validate(generation, entry) {
                return reject(
                    id,
                    ErrorName::IdentityRejected,
                    "on_behalf_of names an entry not assigned to this host",
                );
            }
            entry.clone()
        }
        (None, true) => return reject(id, ErrorName::IdentityRejected, "on_behalf_of is required"),
        _ => String::new(),
    };
    let outcome: Result<Value, RpcResponse> = match method {
        host_protocol::HELLO => parse::<HelloInput>(&params)
            .map_err(|error| error.response(id.clone()))
            .and_then(|hello| {
                core.hosts
                    .hello(generation, hello)
                    .map_err(|error| host_error(id.clone(), error))
            })
            .map(|()| {
                json!(host_protocol::HelloOutput {
                    host_generation: generation,
                    mode: core.mode,
                    heartbeat_interval_ms: host_protocol::HEARTBEAT_INTERVAL_MS,
                    lease_ttl_ms: host_protocol::LEASE_TTL_MS,
                })
            }),
        host_protocol::HEARTBEAT => core
            .hosts
            .heartbeat(generation)
            .map(|()| json!({}))
            .map_err(|error| host_error(id.clone(), error)),
        host_protocol::CAPABILITY_REGISTER => parse::<RegisterInput>(&params)
            .map_err(|error| error.response(id.clone()))
            .and_then(|input| {
                core.hosts
                    .register(generation, &entry_id, &input)
                    .map_err(|error| host_error(id.clone(), error))
            })
            .map(|output| json!(output)),
        host_protocol::CAPABILITY_REVOKE => parse::<RevokeInput>(&params)
            .map_err(|error| error.response(id.clone()))
            .and_then(|input| {
                core.hosts
                    .revoke(generation, &entry_id, &input.lease_id)
                    .map_err(|error| host_error(id.clone(), error))
            })
            .map(|()| json!({})),
        host_protocol::LEASE_RENEW => parse::<RenewInput>(&params)
            .map_err(|error| error.response(id.clone()))
            .and_then(|input| {
                core.hosts
                    .renew(generation, &input)
                    .map_err(|error| host_error(id.clone(), error))
            })
            .map(|output| json!(output)),
        host_protocol::EVENT => parse::<EventInput>(&params)
            .map_err(|error| error.response(id.clone()))
            .and_then(|input| {
                core.hosts
                    .event(generation, &entry_id, input)
                    .map_err(|error| host_error(id.clone(), error))
            })
            .map(|accepted| json!({ "accepted": accepted })),
        host_protocol::ENTRY_STATE => parse::<EntryStateInput>(&params)
            .map_err(|error| error.response(id.clone()))
            .and_then(|input| {
                core.hosts
                    .entry_state(generation, input)
                    .map_err(|error| host_error(id.clone(), error))
            })
            .map(|()| json!({})),
        host_protocol::RESOURCES => parse::<ResourcesInput>(&params)
            .map_err(|error| error.response(id.clone()))
            .and_then(|input| {
                core.hosts
                    .resources(generation, input)
                    .map_err(|error| host_error(id.clone(), error))
            })
            .map(|()| json!({})),
        _ => Err(reject(
            id.clone(),
            ErrorName::Unsupported,
            "unknown host method",
        )),
    };
    match outcome {
        Ok(value) => RpcResponse::ok(id, value),
        Err(response) => response,
    }
}

fn is_control(method: &str) -> bool {
    method == SHELL_REPORT || method.starts_with("host.")
}

/// Route one `desktop.*` request: metadata, identity of the caller (hostd
/// must name an entry Core assigned to it), then the router.
fn dispatch(
    core: &Arc<Core>,
    connection: &Connection,
    sink: &Sender<Outgoing>,
    request: RpcRequest,
    control: &RequestControl,
) -> RpcResponse {
    let started = Instant::now();
    let id = request.id.clone().unwrap_or_default();
    let Value::Object(mut params) = request.params else {
        return reject(id, ErrorName::InvalidParams, "params must be an object");
    };
    if params.contains_key("plugin_id")
        || params.contains_key("client_id")
        || params.contains_key("subject") && !request.method.starts_with("desktop.permissions.")
    {
        return reject(
            id,
            ErrorName::IdentityRejected,
            "caller identity cannot be self-declared",
        );
    }
    let Some(meta) = params.remove("_meta") else {
        return reject(id, ErrorName::InvalidParams, "missing request metadata");
    };
    let Ok(meta) = serde_json::from_value::<RequestMeta>(meta) else {
        return reject(id, ErrorName::InvalidParams, "invalid request metadata");
    };
    if meta.protocol_version != PROTOCOL_VERSION {
        return reject(
            id,
            ErrorName::ProtocolVersionUnsupported,
            "protocol version unsupported",
        );
    }
    let subject = match (&connection.kind[..], &meta.on_behalf_of) {
        ("hostd", Some(entry)) => {
            let generation = connection.host_generation.unwrap_or_default();
            if !core.hosts.validate(generation, entry) {
                return reject(
                    id,
                    ErrorName::IdentityRejected,
                    "on_behalf_of names an entry not assigned to this host",
                );
            }
            Subject::host(entry)
        }
        ("hostd", None) => {
            return reject(
                id,
                ErrorName::IdentityRejected,
                "a hostd call must name the entry it is for",
            )
        }
        (_, Some(_)) => {
            return reject(
                id,
                ErrorName::IdentityRejected,
                "only hostd may call on behalf of an entry",
            )
        }
        (_, None) => connection.subject.clone(),
    };
    let Some(contract) = catalog::contract(&request.method) else {
        return reject(
            id,
            ErrorName::Unsupported,
            "capability is not available in this build",
        );
    };
    if control.cancelled.load(Ordering::SeqCst) {
        return reject(id, ErrorName::Cancelled, "cancelled before execution");
    }
    let requested = meta.deadline_ms.unwrap_or(contract.timeout.default_ms);
    let call = Call {
        id: &id,
        contract: &contract,
        params,
        operation_id: meta.operation_id.clone(),
        deadline: Duration::from_millis(requested.min(contract.timeout.max_ms)),
        started,
        approved_once: false,
    };
    let caller = Caller {
        subject,
        kind: connection.kind.clone(),
        connection_id: connection.connection_id.clone(),
        sink: sink.clone(),
        gone: Arc::clone(&connection.gone),
    };
    match router::dispatch(core, &caller, call) {
        Ok((mut result, readback_verified)) => {
            if let Value::Object(fields) = &mut result {
                fields.insert(
                    "_meta".into(),
                    json!(ResultMeta {
                        observed_seq: core.session.observed_seq(),
                        profile_revision: core.session.profile_revision(),
                        readback_verified,
                        not_cancellable: control
                            .refused_cancel
                            .load(Ordering::SeqCst)
                            .then_some(true),
                        handled_us: Some(
                            u64::try_from(started.elapsed().as_micros()).unwrap_or(u64::MAX),
                        ),
                    }),
                );
            }
            RpcResponse::ok(id, result)
        }
        Err(error) => {
            let mut response = error.response(id);
            if let (Some(rpc), Some(data)) = (response.error.as_mut(), &error.data) {
                if data.get("outcome").and_then(Value::as_str) == Some("unknown") {
                    rpc.outcome = Some(ditto_protocol::rpc::Outcome::Unknown);
                }
            }
            response
        }
    }
}

fn handle_cancel(params: &Value, in_flight: &InFlight) {
    let Some(target) = params.get("id").and_then(Value::as_str) else {
        return;
    };
    let control = in_flight
        .lock()
        .expect("in-flight lock")
        .get(target)
        .cloned();
    let Some(control) = control else {
        return; // Already finished: a late cancel changes nothing.
    };
    if !control.cancellable {
        control.refused_cancel.store(true, Ordering::SeqCst);
        return;
    }
    control.cancelled.store(true, Ordering::SeqCst);
}

/// Serve a single Unix client. The shared token gate is development-only; the
/// controlled launcher path is `serve_bound_connection`.
pub fn serve_connection(
    stream: UnixStream,
    core: Arc<Core>,
    expected_token: &str,
) -> io::Result<()> {
    serve_connection_with_auth(stream, core, AuthMode::DevelopmentToken(expected_token))
}

/// Accept only a one-use launcher binding matching the socket's peer process.
pub fn serve_bound_connection(
    stream: UnixStream,
    core: Arc<Core>,
    registry: &IdentityRegistry,
) -> io::Result<()> {
    serve_connection_with_auth(stream, core, AuthMode::LauncherRegistry(registry))
}

fn write_message(stream: &mut UnixStream, message: Outgoing) -> io::Result<()> {
    let line = match message {
        Outgoing::Response(response) => serde_json::to_vec(&response)?,
        Outgoing::Event(event) => serde_json::to_vec(&json!({
            "jsonrpc": "2.0",
            "method": "desktop.events",
            "params": event,
        }))?,
        Outgoing::Request(request) => serde_json::to_vec(&request)?,
        Outgoing::Shutdown => return Ok(()),
    };
    stream.write_all(&line)?;
    stream.write_all(b"\n")
}

fn serve_connection_with_auth(
    stream: UnixStream,
    core: Arc<Core>,
    auth_mode: AuthMode<'_>,
) -> io::Result<()> {
    let peer = peer_credentials(&stream)?;
    // SAFETY: getuid takes no arguments and has no memory preconditions.
    if peer.uid != unsafe { libc::getuid() } || peer.pid <= 0 {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "peer UID rejected",
        ));
    }
    let (sink, outgoing) = mpsc::channel::<Outgoing>();
    let mut writer_stream = stream.try_clone()?;
    let writer = thread::spawn(move || -> io::Result<()> {
        for message in outgoing {
            if matches!(message, Outgoing::Shutdown) {
                break;
            }
            if let Err(error) = write_message(&mut writer_stream, message) {
                // A client that leaves mid-stream ends the connection; it is
                // not a service failure, and pending work still unwinds.
                if matches!(
                    error.kind(),
                    io::ErrorKind::BrokenPipe | io::ErrorKind::ConnectionReset
                ) {
                    return Ok(());
                }
                return Err(error);
            }
        }
        Ok(())
    });

    let mut reader = BufReader::new(stream.try_clone()?);
    let in_flight: InFlight = Arc::new(Mutex::new(HashMap::new()));
    let mut workers = Vec::new();
    let mut connection: Option<Connection> = None;
    let served = (|| -> io::Result<()> {
        while let Some(line) = read_line_limited(&mut reader)? {
            let Ok(message) = serde_json::from_slice::<Value>(&line) else {
                continue; // Malformed frames are ignored, never guessed at.
            };
            if message.get("jsonrpc").and_then(Value::as_str) != Some("2.0") {
                continue;
            }
            // A response to a request Core sent on this connection.
            if message.get("method").is_none() {
                if let (Some(connection), Ok(response)) =
                    (&connection, serde_json::from_value::<RpcResponse>(message))
                {
                    connection.peer.deliver(response);
                }
                continue;
            }
            let Ok(request) = serde_json::from_value::<RpcRequest>(message) else {
                continue;
            };
            let Some(current) = &connection else {
                match handshake(&core, request, &auth_mode, peer, &sink) {
                    Ok((response, established)) => {
                        let _ = sink.send(Outgoing::Response(Box::new(response)));
                        crate::log::event(
                            "connection.open",
                            &[
                                ("kind", &established.kind),
                                ("connection_id", &established.connection_id),
                            ],
                        );
                        connection = Some(established);
                        continue;
                    }
                    Err(response) => {
                        let _ = sink.send(Outgoing::Response(Box::new(response)));
                        break;
                    }
                }
            };
            let Some(id) = request.id.clone() else {
                if request.method == CANCEL_METHOD {
                    handle_cancel(&request.params, &in_flight);
                }
                continue;
            };
            if id.starts_with(CORE_ID_PREFIX) {
                let _ = sink.send(Outgoing::Response(Box::new(reject(
                    id,
                    ErrorName::InvalidParams,
                    "request ids starting with core- are Core's",
                ))));
                continue;
            }
            if is_control(&request.method) {
                let Value::Object(params) = request.params else {
                    let _ = sink.send(Outgoing::Response(Box::new(reject(
                        id,
                        ErrorName::InvalidParams,
                        "params must be an object",
                    ))));
                    continue;
                };
                let response = control(&core, current, id, &request.method, params);
                let _ = sink.send(Outgoing::Response(Box::new(response)));
                continue;
            }
            let cancellable =
                catalog::contract(&request.method).is_some_and(|contract| contract.cancellable);
            let control = Arc::new(RequestControl {
                cancellable,
                cancelled: AtomicBool::new(false),
                refused_cancel: AtomicBool::new(false),
            });
            in_flight
                .lock()
                .expect("in-flight lock")
                .insert(id.clone(), Arc::clone(&control));
            let worker_core = Arc::clone(&core);
            let worker_sink = sink.clone();
            let worker_in_flight = Arc::clone(&in_flight);
            let snapshot = Connection {
                connection_id: current.connection_id.clone(),
                kind: current.kind.clone(),
                subject: current.subject.clone(),
                peer: Arc::clone(&current.peer),
                host_generation: current.host_generation,
                gone: Arc::clone(&current.gone),
            };
            workers.push(thread::spawn(move || {
                let response = dispatch(&worker_core, &snapshot, &worker_sink, request, &control);
                worker_in_flight.lock().expect("in-flight lock").remove(&id);
                let _ = worker_sink.send(Outgoing::Response(Box::new(response)));
            }));
            workers.retain(|worker| !worker.is_finished());
        }
        Ok(())
    })();
    if let Some(connection) = &connection {
        connection.gone.store(true, Ordering::SeqCst);
        connection.peer.close();
        // Unsent context leaves with the surface that took it; a gone Agent
        // ends its turns, so their context is released too.
        core.contexts.release_owner(&connection.connection_id);
        if connection.kind == "agent" {
            core.contexts.release_bound();
        }
        if connection.kind == "agent" {
            let owner = connection.connection_id.clone();
            core.submit(move |c| {
                let _ = ditto_store::conversations::release_connection(c.store(), &owner);
                let _ = ditto_store::turns::interrupt_connection(c.store(), Some(&owner));
            });
        }
        match connection.kind.as_str() {
            "hostd" => {
                if let Some(generation) = connection.host_generation {
                    core.hosts.detach(generation, "connection_closed");
                }
            }
            "quickshell" if core.shell.detach(&connection.connection_id) => {
                core.note_instability("shell disconnected");
            }
            _ => {}
        }
        let closed: Vec<String> = {
            let mut subscriptions = core.subscriptions.lock().expect("subscriptions");
            let closed: Vec<String> = subscriptions
                .iter()
                .filter(|(_, info)| info.connection_id == connection.connection_id)
                .map(|(id, _)| id.clone())
                .collect();
            for id in &closed {
                subscriptions.remove(id);
            }
            closed
        };
        for subscription in closed {
            core.session.unsubscribe(&subscription);
        }
        crate::log::event(
            "connection.closed",
            &[
                ("kind", &connection.kind),
                ("connection_id", &connection.connection_id),
            ],
        );
    }
    for worker in workers {
        let _ = worker.join();
    }
    // A Peer of this connection may still be held elsewhere (the Agent or
    // Shell manager until its next tick, a waiting request): its sender
    // must not keep the writer, and with it this thread, alive forever.
    let _ = sink.send(Outgoing::Shutdown);
    drop(sink);
    writer
        .join()
        .map_err(|_| io::Error::other("connection writer panicked"))??;
    served
}

pub fn set_private_permissions(path: &std::path::Path, mode: u32) -> io::Result<()> {
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(mode))
}

#[cfg(test)]
mod tests;
