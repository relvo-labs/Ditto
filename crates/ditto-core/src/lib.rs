//! G0 IPC service: newline-framed JSON-RPC over a Unix socket, capability
//! routing with readback, and an observation event stream. Core routes; the
//! compositor adapter provides. No configuration is persisted in G0.

pub mod events;
pub mod identity;
pub mod session;

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

use ditto_compositor::AdapterError;
use ditto_protocol::{
    catalog::{self, Availability, CapabilityContract},
    rpc::{HandshakeInput, HandshakeOutput, Outcome, RpcRequest, RpcResponse},
    CloseRequestOutput, ErrorName, EventsSubscribeInput, EventsSubscribeOutput, OutputsListOutput,
    RequestMeta, ResultMeta, Window, WindowIdInput, WindowMoveInput, WindowResizeInput,
    WindowSetStateInput, WindowsListOutput, Workspace, WorkspaceIdInput, WorkspacesListOutput,
    PROTOCOL_VERSION,
};
use events::Registration;
use identity::IdentityRegistry;
use serde_json::{json, Map, Value};
use session::{Outgoing, Session};

pub const MAX_LINE_BYTES: usize = 1_048_576;
pub const CANCEL_METHOD: &str = "$/cancel";

/// Capabilities with a handler in this build. The catalog consistency gate
/// checks this list against the exported catalog.
pub const HANDLERS: &[&str] = &[
    catalog::CAPABILITIES_LIST,
    catalog::OUTPUTS_LIST,
    catalog::WORKSPACES_LIST,
    catalog::WORKSPACES_GET,
    catalog::WORKSPACES_ACTIVATE,
    catalog::WINDOWS_LIST,
    catalog::WINDOWS_GET,
    catalog::WINDOWS_FOCUS,
    catalog::WINDOWS_MOVE,
    catalog::WINDOWS_RESIZE,
    catalog::WINDOWS_SET_STATE,
    catalog::WINDOWS_CLOSE_REQUEST,
    catalog::EVENTS_SUBSCRIBE,
];

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

fn reject_unknown_outcome(id: String, message: &str) -> RpcResponse {
    let mut response = RpcResponse::error(id, ErrorName::Timeout, message);
    if let Some(error) = response.error.as_mut() {
        // The command reached the compositor; whether it took effect is unknown.
        error.outcome = Some(Outcome::Unknown);
    }
    response
}

enum AuthMode<'a> {
    DevelopmentToken(&'a str),
    LauncherRegistry(&'a IdentityRegistry),
}

/// One in-flight request. Cancellation is refused, never faked: a capability
/// declared non-cancellable reports the refusal on its own response.
struct RequestControl {
    cancellable: bool,
    cancelled: AtomicBool,
    refused_cancel: AtomicBool,
    subscription: Mutex<Option<String>>,
    /// Events retained from before this subscription started. They are sent
    /// after the response, because a consumer cannot place an event for a
    /// subscription it has not been told about yet.
    replay: Mutex<Vec<ditto_protocol::DesktopEventNotification>>,
}

impl RequestControl {
    fn new(cancellable: bool) -> Self {
        Self {
            cancellable,
            cancelled: AtomicBool::new(false),
            refused_cancel: AtomicBool::new(false),
            subscription: Mutex::new(None),
            replay: Mutex::new(Vec::new()),
        }
    }
}

type InFlight = Arc<Mutex<HashMap<String, Arc<RequestControl>>>>;

fn handshake(
    request: RpcRequest,
    auth_mode: &AuthMode<'_>,
    peer: libc::ucred,
    session: &Session,
) -> (RpcResponse, bool) {
    let id = request.id.clone().unwrap_or_else(|| "handshake".into());
    if request.method != "core.handshake" {
        return (
            reject(id, ErrorName::IdentityRejected, "handshake required"),
            false,
        );
    }
    let Ok(input) = serde_json::from_value::<HandshakeInput>(request.params) else {
        return (
            reject(id, ErrorName::InvalidParams, "invalid handshake"),
            false,
        );
    };
    if input.protocol_version != PROTOCOL_VERSION {
        return (
            reject(
                id,
                ErrorName::ProtocolVersionUnsupported,
                "protocol version unsupported",
            ),
            false,
        );
    }
    let accepted = match auth_mode {
        // Development mode has one shared token and takes the client's word for
        // what it is. That is why it is not identity evidence: EX-07 is decided
        // on the launcher path below.
        AuthMode::DevelopmentToken(expected_token) => input.auth.token == *expected_token,
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
    if !accepted {
        return (
            reject(id, ErrorName::IdentityRejected, "identity rejected"),
            false,
        );
    }
    let result = HandshakeOutput {
        protocol_version: PROTOCOL_VERSION.into(),
        catalog_revision: catalog::CATALOG_REVISION,
        server: match auth_mode {
            AuthMode::DevelopmentToken(_) => "ditto-core/g0-development",
            AuthMode::LauncherRegistry(_) => "ditto-core/g0-bound",
        }
        .into(),
        compositor: Some(session.compositor_label()),
    };
    (RpcResponse::ok(id, json!(result)), true)
}

fn served_catalog(session: &Session) -> Value {
    json!(catalog::resolved_catalog(|capability_id, matrix_row| {
        session.availability(capability_id, matrix_row)
    }))
}

fn adapter_error(id: String, error: AdapterError) -> RpcResponse {
    match error {
        AdapterError::Unsupported(reason) => reject(id, ErrorName::Unsupported, &reason),
        AdapterError::NotFound(reason) => reject(id, ErrorName::NotFound, &reason),
        AdapterError::Unavailable(reason) => reject(id, ErrorName::Unavailable, &reason),
        AdapterError::ReadbackMismatch(reason) => reject(id, ErrorName::Conflict, &reason),
        AdapterError::Internal(reason) => reject(id, ErrorName::Internal, &reason),
    }
}

struct Call {
    id: String,
    params: Map<String, Value>,
    meta: RequestMeta,
    contract: CapabilityContract,
    started: Instant,
}

impl Call {
    fn deadline(&self) -> Duration {
        let requested = self
            .meta
            .deadline_ms
            .unwrap_or(self.contract.timeout.default_ms);
        Duration::from_millis(requested.min(self.contract.timeout.max_ms))
    }

    fn expired(&self) -> bool {
        self.started.elapsed() > self.deadline()
    }

    fn input<T: serde::de::DeserializeOwned>(&self) -> Result<T, RpcResponse> {
        serde_json::from_value(Value::Object(self.params.clone())).map_err(|error| {
            reject(
                self.id.clone(),
                ErrorName::InvalidParams,
                &format!("invalid parameters: {error}"),
            )
        })
    }
}

fn dispatch(
    session: &Arc<Session>,
    request: RpcRequest,
    control: &Arc<RequestControl>,
    sink: &Sender<Outgoing>,
) -> RpcResponse {
    let started = Instant::now();
    let id = request.id.clone().unwrap_or_default();
    let Value::Object(mut params) = request.params else {
        return reject(id, ErrorName::InvalidParams, "params must be an object");
    };
    if params.contains_key("plugin_id") || params.contains_key("client_id") {
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
    let Some(contract) = catalog::contract(&request.method) else {
        return reject(
            id,
            ErrorName::Unsupported,
            "capability is not available in this build",
        );
    };
    let call = Call {
        id: id.clone(),
        params,
        meta,
        contract,
        started,
    };
    if let Some(matrix_row) = call.contract.matrix_row {
        // The catalog answers availability before the call, so a consumer never
        // has to fail once to learn that a capability has no compositor path.
        if let Availability::DependsOnCompositor {
            available: false,
            reason,
            ..
        } = session.availability(call.contract.capability_id, matrix_row)
        {
            let reason = reason.unwrap_or_else(|| "compositor gap".into());
            let name = if session.is_online() {
                ErrorName::Unsupported
            } else {
                ErrorName::Unavailable
            };
            return reject(id, name, &reason);
        }
    }
    if control.cancelled.load(Ordering::SeqCst) {
        return reject(id, ErrorName::Cancelled, "cancelled before execution");
    }
    match execute(session, &call, control, sink) {
        Ok((result, readback_verified)) => {
            let mut result = result;
            if let Value::Object(fields) = &mut result {
                fields.insert(
                    "_meta".into(),
                    json!(ResultMeta {
                        revision: session.observation_revision(),
                        readback_verified,
                        not_cancellable: control
                            .refused_cancel
                            .load(Ordering::SeqCst)
                            .then_some(true),
                    }),
                );
            }
            RpcResponse::ok(id, result)
        }
        Err(response) => response,
    }
}

/// Run the capability and, for writes, verify the result by reading the state
/// back. A write whose readback disagrees is a failure, not a success.
fn execute(
    session: &Arc<Session>,
    call: &Call,
    control: &Arc<RequestControl>,
    sink: &Sender<Outgoing>,
) -> Result<(Value, bool), RpcResponse> {
    let id = call.id.clone();
    let no_input = |call: &Call| -> Result<(), RpcResponse> {
        if call.params.is_empty() {
            return Ok(());
        }
        Err(reject(
            call.id.clone(),
            ErrorName::InvalidParams,
            "unexpected capability parameters",
        ))
    };
    let read = |outcome: Result<Value, AdapterError>| -> Result<(Value, bool), RpcResponse> {
        let value = outcome.map_err(|error| adapter_error(id.clone(), error))?;
        if call.expired() {
            return Err(reject(
                id.clone(),
                ErrorName::Timeout,
                "read exceeded deadline",
            ));
        }
        Ok((value, false))
    };

    match call.contract.capability_id {
        catalog::CAPABILITIES_LIST => {
            no_input(call)?;
            Ok((served_catalog(session), false))
        }
        catalog::OUTPUTS_LIST => {
            no_input(call)?;
            read(
                session
                    .with_adapter(|adapter| adapter.outputs())
                    .map(|outputs| json!(OutputsListOutput { outputs })),
            )
        }
        catalog::WORKSPACES_LIST => {
            no_input(call)?;
            read(
                session
                    .with_adapter(|adapter| adapter.workspaces())
                    .map(|workspaces| json!(WorkspacesListOutput { workspaces })),
            )
        }
        catalog::WORKSPACES_GET => {
            let input: WorkspaceIdInput = call.input()?;
            read(
                session
                    .with_adapter(|adapter| adapter.workspace(&input.workspace_id))
                    .map(|workspace| json!(workspace)),
            )
        }
        catalog::WINDOWS_LIST => {
            no_input(call)?;
            read(
                session
                    .with_adapter(|adapter| adapter.windows())
                    .map(|windows| json!(WindowsListOutput { windows })),
            )
        }
        catalog::WINDOWS_GET => {
            let input: WindowIdInput = call.input()?;
            read(
                session
                    .with_adapter(|adapter| adapter.window(&input.window_id))
                    .map(|window| json!(window)),
            )
        }
        catalog::WORKSPACES_ACTIVATE => {
            let input: WorkspaceIdInput = call.input()?;
            let workspace_id = input.workspace_id.clone();
            session
                .with_adapter(|adapter| adapter.activate_workspace(&workspace_id))
                .map_err(|error| adapter_error(id.clone(), error))?;
            let observed = readback_workspace(session, call, &input.workspace_id)?;
            if !observed.active {
                return Err(reject(
                    id,
                    ErrorName::Conflict,
                    &format!("readback shows workspace {} is not active", observed.id),
                ));
            }
            Ok((json!(observed), true))
        }
        catalog::WINDOWS_FOCUS => {
            let input: WindowIdInput = call.input()?;
            let window_id = input.window_id.clone();
            session
                .with_adapter(|adapter| adapter.focus_window(&window_id))
                .map_err(|error| adapter_error(id.clone(), error))?;
            let observed = readback_window(session, call, &input.window_id)?;
            if !observed.focused {
                return Err(reject(
                    id,
                    ErrorName::Conflict,
                    "readback shows the window is not focused",
                ));
            }
            Ok((json!(observed), true))
        }
        catalog::WINDOWS_MOVE => {
            let input: WindowMoveInput = call.input()?;
            let (window_id, x, y) = (input.window_id.clone(), input.x, input.y);
            session
                .with_adapter(|adapter| adapter.move_window(&window_id, x, y))
                .map_err(|error| adapter_error(id.clone(), error))?;
            let observed = readback_window(session, call, &input.window_id)?;
            if observed.x != Some(input.x) || observed.y != Some(input.y) {
                return Err(reject(
                    id,
                    ErrorName::Conflict,
                    &format!(
                        "readback shows position {:?},{:?} instead of {},{}",
                        observed.x, observed.y, input.x, input.y
                    ),
                ));
            }
            Ok((json!(observed), true))
        }
        catalog::WINDOWS_RESIZE => {
            let input: WindowResizeInput = call.input()?;
            let (window_id, width, height) = (input.window_id.clone(), input.width, input.height);
            session
                .with_adapter(|adapter| adapter.resize_window(&window_id, width, height))
                .map_err(|error| adapter_error(id.clone(), error))?;
            let observed = readback_window(session, call, &input.window_id)?;
            if observed.width != Some(input.width) || observed.height != Some(input.height) {
                return Err(reject(
                    id,
                    ErrorName::Conflict,
                    &format!(
                        "readback shows size {:?}x{:?} instead of {}x{}",
                        observed.width, observed.height, input.width, input.height
                    ),
                ));
            }
            Ok((json!(observed), true))
        }
        catalog::WINDOWS_SET_STATE => {
            let input: WindowSetStateInput = call.input()?;
            let (window_id, state) = (input.window_id.clone(), input.state.clone());
            session
                .with_adapter(|adapter| adapter.set_window_state(&window_id, &state))
                .map_err(|error| adapter_error(id.clone(), error))?;
            let observed = readback_window(session, call, &input.window_id)?;
            if observed.state != input.state {
                return Err(reject(
                    id,
                    ErrorName::Conflict,
                    &format!("readback shows state {:?}", observed.state),
                ));
            }
            Ok((json!(observed), true))
        }
        catalog::WINDOWS_CLOSE_REQUEST => {
            let input: WindowIdInput = call.input()?;
            let window_id = input.window_id.clone();
            session
                .with_adapter(|adapter| adapter.close_request(&window_id))
                .map_err(|error| adapter_error(id.clone(), error))?;
            // Delivery only: the application may still refuse to close, so the
            // caller confirms the outcome through windows.list or an event.
            let operation_id = call
                .meta
                .operation_id
                .clone()
                .unwrap_or_else(|| format!("close-{}", input.window_id.0));
            Ok((
                json!(CloseRequestOutput {
                    accepted: true,
                    operation_id,
                }),
                false,
            ))
        }
        catalog::EVENTS_SUBSCRIBE => {
            let input: EventsSubscribeInput = call.input()?;
            let (registration, resynced) = match session.subscribe(input.after_seq, sink.clone()) {
                Registration::Ready {
                    subscription_id,
                    snapshot,
                    seq,
                    replay,
                } => ((subscription_id, snapshot, seq, replay), false),
                Registration::ResyncRequired => match session.subscribe(None, sink.clone()) {
                    Registration::Ready {
                        subscription_id,
                        snapshot,
                        seq,
                        replay,
                    } => ((subscription_id, snapshot, seq, replay), true),
                    Registration::ResyncRequired => {
                        return Err(reject(
                            id,
                            ErrorName::Internal,
                            "subscription could not be established",
                        ))
                    }
                },
            };
            let (subscription_id, snapshot, seq, replay) = registration;
            *control.subscription.lock().expect("subscription lock") =
                Some(subscription_id.clone());
            *control.replay.lock().expect("replay lock") = replay;
            Ok((
                json!(EventsSubscribeOutput {
                    subscription_id,
                    snapshot,
                    seq,
                    resynced: resynced.then_some(true),
                }),
                false,
            ))
        }
        other => Err(reject(
            id,
            ErrorName::Unsupported,
            &format!("{other} has no handler"),
        )),
    }
}

fn readback_window(
    session: &Arc<Session>,
    call: &Call,
    window_id: &ditto_protocol::WindowSessionId,
) -> Result<Window, RpcResponse> {
    if call.expired() {
        return Err(reject_unknown_outcome(
            call.id.clone(),
            "deadline passed before the result could be read back",
        ));
    }
    session
        .with_adapter(|adapter| adapter.window(window_id))
        .map_err(|error| adapter_error(call.id.clone(), error))
}

fn readback_workspace(
    session: &Arc<Session>,
    call: &Call,
    workspace_id: &str,
) -> Result<Workspace, RpcResponse> {
    if call.expired() {
        return Err(reject_unknown_outcome(
            call.id.clone(),
            "deadline passed before the result could be read back",
        ));
    }
    session
        .with_adapter(|adapter| adapter.workspace(workspace_id))
        .map_err(|error| adapter_error(call.id.clone(), error))
}

fn handle_cancel(session: &Arc<Session>, params: &Value, in_flight: &InFlight) {
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
    let subscription = control
        .subscription
        .lock()
        .expect("subscription lock")
        .take();
    if let Some(subscription) = subscription {
        session.unsubscribe(&subscription);
    }
}

/// Serve a single Unix client. The shared token gate is development-only; the
/// controlled launcher path is `serve_bound_connection`.
pub fn serve_connection(
    stream: UnixStream,
    session: Arc<Session>,
    expected_token: &str,
) -> io::Result<()> {
    serve_connection_with_auth(stream, session, AuthMode::DevelopmentToken(expected_token))
}

/// Accept only a one-use launcher binding matching the socket's peer process.
pub fn serve_bound_connection(
    stream: UnixStream,
    session: Arc<Session>,
    registry: &IdentityRegistry,
) -> io::Result<()> {
    serve_connection_with_auth(stream, session, AuthMode::LauncherRegistry(registry))
}

fn serve_connection_with_auth(
    stream: UnixStream,
    session: Arc<Session>,
    auth_mode: AuthMode<'_>,
) -> io::Result<()> {
    // SAFETY: getuid takes no arguments and has no memory preconditions.
    let peer = peer_credentials(&stream)?;
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
            let line = match message {
                Outgoing::Response(response) => serde_json::to_vec(&response)?,
                Outgoing::Event(event) => serde_json::to_vec(&json!({
                    "jsonrpc": "2.0",
                    "method": "desktop.events",
                    "params": event,
                }))?,
            };
            if let Err(error) = writer_stream
                .write_all(&line)
                .and_then(|()| writer_stream.write_all(b"\n"))
            {
                // A client that leaves mid-stream ends the connection; it is not
                // a service failure, and pending work still unwinds normally.
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
    let mut authenticated = false;
    let mut subscriptions: Vec<String> = Vec::new();
    while let Some(line) = read_line_limited(&mut reader)? {
        let request: RpcRequest = match serde_json::from_slice::<RpcRequest>(&line) {
            Ok(request) if request.jsonrpc == "2.0" => request,
            _ => continue, // Malformed frames are ignored, never guessed at.
        };
        if !authenticated {
            let (response, accepted) = handshake(request, &auth_mode, peer, &session);
            let _ = sink.send(Outgoing::Response(Box::new(response)));
            if !accepted {
                break;
            }
            authenticated = true;
            continue;
        }
        if request.id.is_none() {
            if request.method == CANCEL_METHOD {
                handle_cancel(&session, &request.params, &in_flight);
            }
            continue;
        }
        let id = request.id.clone().expect("request id present");
        let cancellable = catalog::contract(&request.method)
            .map(|contract| contract.cancellable)
            .unwrap_or(false);
        let control = Arc::new(RequestControl::new(cancellable));
        in_flight
            .lock()
            .expect("in-flight lock")
            .insert(id.clone(), Arc::clone(&control));
        let worker_session = Arc::clone(&session);
        let worker_sink = sink.clone();
        let worker_in_flight = Arc::clone(&in_flight);
        workers.push(thread::spawn(move || {
            let response = dispatch(&worker_session, request, &control, &worker_sink);
            worker_in_flight.lock().expect("in-flight lock").remove(&id);
            let subscription = control
                .subscription
                .lock()
                .expect("subscription lock")
                .clone();
            let replay = std::mem::take(&mut *control.replay.lock().expect("replay lock"));
            let _ = worker_sink.send(Outgoing::Response(Box::new(response)));
            for event in replay {
                let _ = worker_sink.send(Outgoing::Event(Box::new(event)));
            }
            subscription
        }));
    }
    for worker in workers {
        if let Ok(Some(subscription)) = worker.join() {
            subscriptions.push(subscription);
        }
    }
    for subscription in subscriptions {
        session.unsubscribe(&subscription);
    }
    drop(sink);
    writer
        .join()
        .map_err(|_| io::Error::other("connection writer panicked"))??;
    Ok(())
}

pub fn set_private_permissions(path: &std::path::Path, mode: u32) -> io::Result<()> {
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(mode))
}

#[cfg(test)]
mod tests;
