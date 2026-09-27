//! Requests Core sends to a connected client. Protocol 0.2 runs requests in
//! both directions on one connection: Core's ids start with `core-`, and the
//! connection reader hands each response back here instead of treating it as
//! a request.

use std::{
    collections::HashMap,
    sync::{
        atomic::{AtomicBool, AtomicU64, Ordering},
        mpsc::{self, Sender},
        Mutex,
    },
    time::Duration,
};

use ditto_protocol::rpc::{RpcError, RpcRequest, RpcResponse};
use serde_json::Value;

use crate::session::Outgoing;

pub const CORE_ID_PREFIX: &str = "core-";

#[derive(Clone, Debug, PartialEq)]
pub enum PeerError {
    /// The connection is gone; whatever the request did is unknown.
    Disconnected,
    Timeout,
    Remote(RpcError),
}

impl std::fmt::Display for PeerError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Disconnected => write!(formatter, "peer disconnected"),
            Self::Timeout => write!(formatter, "peer did not answer in time"),
            Self::Remote(error) => {
                write!(formatter, "peer refused: {} {}", error.code, error.message)
            }
        }
    }
}

type Waiter = Sender<Result<Value, PeerError>>;

pub struct Peer {
    pub connection_id: String,
    pub kind: String,
    pub pid: u32,
    sink: Sender<Outgoing>,
    pending: Mutex<HashMap<String, Waiter>>,
    next: AtomicU64,
    closed: AtomicBool,
}

impl Peer {
    pub fn new(connection_id: String, kind: String, pid: u32, sink: Sender<Outgoing>) -> Self {
        Self {
            connection_id,
            kind,
            pid,
            sink,
            pending: Mutex::new(HashMap::new()),
            next: AtomicU64::new(0),
            closed: AtomicBool::new(false),
        }
    }

    pub fn is_closed(&self) -> bool {
        self.closed.load(Ordering::SeqCst)
    }

    /// Send a request and wait for its response, at most `timeout`. A timeout
    /// does not cancel what the peer may already be doing; callers decide the
    /// outcome from a readback, never from the missing answer.
    pub fn request(
        &self,
        method: &str,
        params: Value,
        timeout: Duration,
    ) -> Result<Value, PeerError> {
        if self.is_closed() {
            return Err(PeerError::Disconnected);
        }
        let id = format!(
            "{CORE_ID_PREFIX}{}",
            self.next.fetch_add(1, Ordering::SeqCst) + 1
        );
        let (waiter, answer) = mpsc::channel();
        self.pending
            .lock()
            .expect("peer pending lock")
            .insert(id.clone(), waiter);
        let request = RpcRequest {
            jsonrpc: "2.0".into(),
            id: Some(id.clone()),
            method: method.into(),
            params,
        };
        if self
            .sink
            .send(Outgoing::Request(Box::new(request)))
            .is_err()
        {
            self.pending.lock().expect("peer pending lock").remove(&id);
            return Err(PeerError::Disconnected);
        }
        let outcome = answer.recv_timeout(timeout);
        self.pending.lock().expect("peer pending lock").remove(&id);
        match outcome {
            Ok(result) => result,
            Err(mpsc::RecvTimeoutError::Timeout) => Err(PeerError::Timeout),
            Err(mpsc::RecvTimeoutError::Disconnected) => Err(PeerError::Disconnected),
        }
    }

    /// A notification: no id, no answer.
    pub fn notify(&self, method: &str, params: Value) -> bool {
        if self.is_closed() {
            return false;
        }
        self.sink
            .send(Outgoing::Request(Box::new(RpcRequest {
                jsonrpc: "2.0".into(),
                id: None,
                method: method.into(),
                params,
            })))
            .is_ok()
    }

    /// Hand a response to its waiter. Returns false for an id Core did not
    /// issue or no longer waits for (a late answer after a timeout).
    pub fn deliver(&self, response: RpcResponse) -> bool {
        let waiter = self
            .pending
            .lock()
            .expect("peer pending lock")
            .remove(&response.id);
        let Some(waiter) = waiter else {
            return false;
        };
        let outcome = match (response.result, response.error) {
            (_, Some(error)) => Err(PeerError::Remote(error)),
            (Some(result), None) => Ok(result),
            (None, None) => Ok(Value::Null),
        };
        waiter.send(outcome).is_ok()
    }

    /// The connection ended: every waiter learns it now, not at its timeout.
    pub fn close(&self) {
        self.closed.store(true, Ordering::SeqCst);
        let waiters: Vec<Waiter> = self
            .pending
            .lock()
            .expect("peer pending lock")
            .drain()
            .map(|(_, waiter)| waiter)
            .collect();
        for waiter in waiters {
            let _ = waiter.send(Err(PeerError::Disconnected));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{sync::Arc, thread};

    #[test]
    fn responses_reach_their_request_and_closing_fails_waiters_at_once() {
        let (sink, outgoing) = mpsc::channel();
        let peer = Arc::new(Peer::new("conn-1".into(), "quickshell".into(), 1, sink));
        let answering = Arc::clone(&peer);
        let responder = thread::spawn(move || {
            let Ok(Outgoing::Request(request)) = outgoing.recv() else {
                panic!()
            };
            assert!(request.id.as_deref().unwrap().starts_with(CORE_ID_PREFIX));
            answering.deliver(RpcResponse::ok(
                request.id.unwrap(),
                serde_json::json!({"ok": true}),
            ));
            outgoing
        });
        let answer = peer
            .request(
                "participant.state",
                serde_json::json!({}),
                Duration::from_secs(2),
            )
            .unwrap();
        assert_eq!(answer["ok"], true);
        let _outgoing = responder.join().unwrap();
        let waiting = Arc::clone(&peer);
        let started = std::time::Instant::now();
        let blocked = thread::spawn(move || {
            waiting.request(
                "participant.prepare",
                serde_json::json!({}),
                Duration::from_secs(10),
            )
        });
        thread::sleep(Duration::from_millis(50));
        peer.close();
        assert_eq!(blocked.join().unwrap(), Err(PeerError::Disconnected));
        assert!(started.elapsed() < Duration::from_secs(2));
    }
}
