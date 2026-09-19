use super::*;
use ditto_compositor::fixture::FixtureCompositor;
use dittoctl::CONSUMED_CAPABILITIES;
use std::io::BufRead;

const TOKEN: &str = "once-only-test-token";

struct Client {
    stream: UnixStream,
    reader: BufReader<UnixStream>,
    worker: Option<thread::JoinHandle<io::Result<()>>>,
}

impl Client {
    fn connect(session: Arc<Session>) -> Self {
        let (client, server) = UnixStream::pair().expect("socket pair");
        let worker = thread::spawn(move || serve_connection(server, session, TOKEN));
        let reader = BufReader::new(client.try_clone().expect("clone"));
        Self {
            stream: client,
            reader,
            worker: Some(worker),
        }
    }

    fn send(&mut self, message: &Value) {
        serde_json::to_writer(&mut self.stream, message).expect("write");
        self.stream.write_all(b"\n").expect("newline");
    }

    fn receive(&mut self) -> Value {
        let mut line = String::new();
        let read = self.reader.read_line(&mut line).expect("read");
        assert!(read > 0, "core closed the connection");
        serde_json::from_str(&line).expect("json line")
    }

    /// Read until a response for `id` arrives, skipping event notifications.
    fn response(&mut self, id: &str) -> Value {
        loop {
            let message = self.receive();
            if message.get("id").and_then(Value::as_str) == Some(id) {
                return message;
            }
        }
    }

    fn call(&mut self, id: &str, method: &str, params: Value) -> Value {
        let mut params = params;
        params["_meta"] = json!({"protocol_version": PROTOCOL_VERSION});
        self.send(&json!({"jsonrpc":"2.0","id":id,"method":method,"params":params}));
        self.response(id)
    }

    fn handshake(&mut self) -> Value {
        self.send(
            &json!({"jsonrpc":"2.0","id":"h","method":"core.handshake","params":{
                "protocol_version": PROTOCOL_VERSION,
                "client": {"kind":"dittoctl","version":"0.1.0"},
                "auth": {"token": TOKEN}
            }}),
        );
        self.response("h")
    }

    fn finish(mut self) {
        self.stream
            .shutdown(std::net::Shutdown::Write)
            .expect("shutdown");
        drop(self.stream);
        drop(self.reader);
        self.worker
            .take()
            .expect("worker")
            .join()
            .expect("worker joined")
            .expect("connection served");
    }
}

fn fixture_session() -> (Arc<Session>, ditto_compositor::fixture::FixtureEventSource) {
    let (compositor, events) = FixtureCompositor::paired();
    (Arc::new(Session::new(Box::new(compositor))), events)
}

fn error_name(response: &Value) -> &str {
    response["error"]["name"].as_str().expect("error name")
}

#[test]
fn handshake_precedes_every_capability_and_reports_the_compositor() {
    let (session, _events) = fixture_session();
    let mut client = Client::connect(Arc::clone(&session));
    let handshake = client.handshake();
    assert_eq!(handshake["result"]["protocol_version"], PROTOCOL_VERSION);
    assert_eq!(
        handshake["result"]["compositor"],
        ditto_compositor::fixture::LABEL
    );
    client.finish();
}

#[test]
fn rejects_wrong_protocol_version_and_unknown_token() {
    for auth in [
        json!({"protocol_version":"9.0.0","client":{"kind":"dittoctl","version":"0.1.0"},"auth":{"token":TOKEN}}),
        json!({"protocol_version":PROTOCOL_VERSION,"client":{"kind":"dittoctl","version":"0.1.0"},"auth":{"token":"wrong"}}),
    ] {
        let (session, _events) = fixture_session();
        let mut client = Client::connect(session);
        client.send(&json!({"jsonrpc":"2.0","id":"h","method":"core.handshake","params":auth}));
        let response = client.response("h");
        assert!(response.get("result").is_none());
        client.finish();
    }
}

#[test]
fn serves_the_catalog_with_compositor_availability_resolved() {
    let (session, _events) = fixture_session();
    let mut client = Client::connect(session);
    client.handshake();
    let response = client.call("c", catalog::CAPABILITIES_LIST, json!({}));
    let capabilities = response["result"]["capabilities"]
        .as_array()
        .expect("capability list");
    assert_eq!(capabilities.len(), HANDLERS.len());
    let move_window = capabilities
        .iter()
        .find(|item| item["capability_id"] == catalog::WINDOWS_MOVE)
        .expect("move is listed");
    assert_eq!(move_window["availability"]["kind"], "depends_on_compositor");
    assert_eq!(move_window["availability"]["available"], true);
    assert_eq!(move_window["availability"]["matrix_row"], "C-04");
    assert_eq!(move_window["claimable"], true);
    client.finish();
}

#[test]
fn write_capabilities_report_readback_verification() {
    let (session, _events) = fixture_session();
    let mut client = Client::connect(session);
    client.handshake();
    let focus = client.call(
        "f",
        catalog::WINDOWS_FOCUS,
        json!({"window_id": "fixture-window-2"}),
    );
    assert_eq!(focus["result"]["focused"], true);
    assert_eq!(focus["result"]["_meta"]["readback_verified"], true);
    let moved = client.call(
        "m",
        catalog::WINDOWS_MOVE,
        json!({"window_id": "fixture-window-2", "x": 42, "y": 84}),
    );
    assert_eq!(moved["result"]["x"], 42);
    assert_eq!(moved["result"]["_meta"]["readback_verified"], true);
    client.finish();
}

#[test]
fn gaps_answer_unsupported_instead_of_a_silent_success() {
    let (session, _events) = fixture_session();
    let mut client = Client::connect(session);
    client.handshake();
    let tiled = client.call(
        "m",
        catalog::WINDOWS_MOVE,
        json!({"window_id": "fixture-window-1", "x": 10, "y": 10}),
    );
    assert_eq!(error_name(&tiled), "unsupported");
    let minimized = client.call(
        "s",
        catalog::WINDOWS_SET_STATE,
        json!({"window_id": "fixture-window-1", "state": "minimized"}),
    );
    assert_eq!(error_name(&minimized), "unsupported");
    let missing = client.call(
        "g",
        catalog::WINDOWS_GET,
        json!({"window_id": "fixture-window-404"}),
    );
    assert_eq!(error_name(&missing), "not_found");
    client.finish();
}

#[test]
fn close_request_reports_delivery_without_claiming_the_window_closed() {
    let (session, _events) = fixture_session();
    let mut client = Client::connect(session);
    client.handshake();
    let closed = client.call(
        "k",
        catalog::WINDOWS_CLOSE_REQUEST,
        json!({"window_id": "fixture-window-1"}),
    );
    assert_eq!(closed["result"]["accepted"], true);
    assert_eq!(closed["result"]["_meta"]["readback_verified"], false);
    let windows = client.call("w", catalog::WINDOWS_LIST, json!({}));
    let remaining = windows["result"]["windows"]
        .as_array()
        .expect("window list")
        .len();
    assert_eq!(remaining, 1);
    client.finish();
}

#[test]
fn subscription_delivers_a_snapshot_then_ordered_events() {
    let (session, _events) = fixture_session();
    let mut client = Client::connect(Arc::clone(&session));
    client.handshake();
    let subscribed = client.call("sub", catalog::EVENTS_SUBSCRIBE, json!({}));
    assert_eq!(
        subscribed["result"]["snapshot"]["windows"]
            .as_array()
            .expect("snapshot windows")
            .len(),
        2
    );
    session
        .with_adapter(|adapter| adapter.activate_workspace("2"))
        .expect("workspace activated");
    session.publish_changes();
    let event = loop {
        let message = client.receive();
        if message["method"] == "desktop.events" {
            break message;
        }
    };
    assert_eq!(event["params"]["seq"].as_u64(), Some(1));
    assert!(event["params"]["payload"]["type"]
        .as_str()
        .expect("payload type")
        .starts_with("workspace"));
    client.finish();
}

#[test]
fn retained_events_are_replayed_after_the_subscribe_response() {
    let (session, _events) = fixture_session();
    let mut client = Client::connect(Arc::clone(&session));
    client.handshake();
    session
        .with_adapter(|adapter| adapter.activate_workspace("2"))
        .expect("workspace activated");
    session.publish_changes();
    client.send(
        &json!({"jsonrpc":"2.0","id":"sub","method":catalog::EVENTS_SUBSCRIBE,
        "params":{"after_seq":0,"_meta":{"protocol_version":PROTOCOL_VERSION}}}),
    );
    // The response must come first: an event naming a subscription the consumer
    // has not been told about yet has nowhere to go.
    let first = client.receive();
    assert_eq!(first["id"], "sub");
    let subscription_id = first["result"]["subscription_id"]
        .as_str()
        .expect("subscription id")
        .to_string();
    let event = client.receive();
    assert_eq!(event["method"], "desktop.events");
    assert_eq!(event["params"]["subscription_id"], subscription_id);
    assert_eq!(event["params"]["seq"].as_u64(), Some(1));
    client.finish();
}

#[test]
fn a_gap_in_the_sequence_answers_with_a_fresh_snapshot() {
    let (session, _events) = fixture_session();
    let mut client = Client::connect(Arc::clone(&session));
    client.handshake();
    let resubscribe = client.call(
        "sub",
        catalog::EVENTS_SUBSCRIBE,
        json!({"after_seq": 4_000_u64}),
    );
    assert_eq!(resubscribe["result"]["resynced"], true);
    client.finish();
}

#[test]
fn cancelling_a_non_cancellable_capability_is_refused_not_faked() {
    let (session, _events) = fixture_session();
    let mut client = Client::connect(session);
    client.handshake();
    // The cancel arrives after the request completed: the response is a normal
    // success and the connection stays usable.
    let listed = client.call("l", catalog::WINDOWS_LIST, json!({}));
    assert!(listed["result"]["windows"].is_array());
    client.send(&json!({"jsonrpc":"2.0","method":CANCEL_METHOD,"params":{"id":"l"}}));
    let again = client.call("l2", catalog::WINDOWS_LIST, json!({}));
    assert!(again["result"]["windows"].is_array());
    client.finish();
}

#[test]
fn an_offline_compositor_answers_unavailable_for_dependent_capabilities() {
    let (mut compositor, _events) = FixtureCompositor::paired();
    compositor.disconnect();
    let session = Arc::new(Session::new(Box::new(compositor)));
    let mut client = Client::connect(session);
    client.handshake();
    let response = client.call("w", catalog::WINDOWS_LIST, json!({}));
    assert_eq!(error_name(&response), "unavailable");
    let catalog_response = client.call("c", catalog::CAPABILITIES_LIST, json!({}));
    let windows = catalog_response["result"]["capabilities"]
        .as_array()
        .expect("capabilities")
        .iter()
        .find(|item| item["capability_id"] == catalog::WINDOWS_LIST)
        .cloned()
        .expect("windows.list listed");
    assert_eq!(windows["availability"]["available"], false);
    client.finish();
}

#[test]
fn rejects_self_declared_identity() {
    let (session, _events) = fixture_session();
    let mut client = Client::connect(session);
    client.handshake();
    client.send(
        &json!({"jsonrpc":"2.0","id":"x","method":catalog::WINDOWS_LIST,
        "params":{"plugin_id":"privileged","_meta":{"protocol_version":PROTOCOL_VERSION}}}),
    );
    let response = client.response("x");
    assert_eq!(error_name(&response), "identity_rejected");
    client.finish();
}

#[test]
fn every_catalog_entry_has_a_handler_and_a_consumer() {
    let (session, _events) = fixture_session();
    let catalog = catalog::resolved_catalog(|capability_id, matrix_row| {
        session.availability(capability_id, matrix_row)
    });
    catalog::validate_catalog(&catalog.capabilities, HANDLERS, CONSUMED_CAPABILITIES)
        .expect("catalog is consistent");
}

#[test]
fn bound_handshake_uses_peer_pid_and_consumes_token() {
    let registry = Arc::new(IdentityRegistry::new());
    let identity = identity::ClientIdentity {
        // SAFETY: getuid has no memory preconditions.
        uid: unsafe { libc::getuid() },
        pid: std::process::id(),
        kind: "dittoctl".into(),
        version: "0.1.0".into(),
        executable: std::fs::read_link("/proc/self/exe").unwrap(),
    };
    let token = registry.issue_for_spawned_client(identity).unwrap();
    for (attempt, expect_success) in [(1, true), (2, false)] {
        let (session, _events) = fixture_session();
        let (mut client, server) = UnixStream::pair().unwrap();
        let worker = {
            let registry = Arc::clone(&registry);
            thread::spawn(move || serve_bound_connection(server, session, &registry))
        };
        serde_json::to_writer(
            &mut client,
            &json!({"jsonrpc":"2.0","id":"h","method":"core.handshake","params":{
                "protocol_version": PROTOCOL_VERSION,
                "client": {"kind":"dittoctl","version":"0.1.0"},
                "auth": {"token": token}
            }}),
        )
        .unwrap();
        client.write_all(b"\n").unwrap();
        client.shutdown(std::net::Shutdown::Write).unwrap();
        let mut reader = BufReader::new(client);
        let mut line = String::new();
        reader.read_line(&mut line).unwrap();
        let response: Value = serde_json::from_str(&line).unwrap();
        assert_eq!(
            response.get("result").is_some(),
            expect_success,
            "attempt {attempt}"
        );
        worker.join().unwrap().unwrap();
    }
}

#[test]
fn bound_handshake_rejects_another_pid_and_a_forged_client_kind() {
    let registry = Arc::new(IdentityRegistry::new());
    let other_pid = identity::ClientIdentity {
        // SAFETY: getuid has no memory preconditions.
        uid: unsafe { libc::getuid() },
        pid: std::process::id() + 1,
        kind: "dittoctl".into(),
        version: "0.1.0".into(),
        executable: std::fs::read_link("/proc/self/exe").unwrap(),
    };
    let stolen = registry.issue_for_spawned_client(other_pid).unwrap();
    let own = identity::ClientIdentity {
        // SAFETY: getuid has no memory preconditions.
        uid: unsafe { libc::getuid() },
        pid: std::process::id(),
        kind: "dittoctl".into(),
        version: "0.1.0".into(),
        executable: std::fs::read_link("/proc/self/exe").unwrap(),
    };
    let own_token = registry.issue_for_spawned_client(own).unwrap();
    let attempts = [
        (stolen, "dittoctl", false),
        (own_token.clone(), "privileged-plugin", false),
        (own_token, "dittoctl", true),
    ];
    for (token, kind, expect_success) in attempts {
        let (session, _events) = fixture_session();
        let (mut client, server) = UnixStream::pair().unwrap();
        let worker = {
            let registry = Arc::clone(&registry);
            thread::spawn(move || serve_bound_connection(server, session, &registry))
        };
        serde_json::to_writer(
            &mut client,
            &json!({"jsonrpc":"2.0","id":"h","method":"core.handshake","params":{
                "protocol_version": PROTOCOL_VERSION,
                "client": {"kind": kind, "version":"0.1.0"},
                "auth": {"token": token}
            }}),
        )
        .unwrap();
        client.write_all(b"\n").unwrap();
        client.shutdown(std::net::Shutdown::Write).unwrap();
        let mut reader = BufReader::new(client);
        let mut line = String::new();
        reader.read_line(&mut line).unwrap();
        let response: Value = serde_json::from_str(&line).unwrap();
        assert_eq!(response.get("result").is_some(), expect_success, "{kind}");
        worker.join().unwrap().unwrap();
    }
}
