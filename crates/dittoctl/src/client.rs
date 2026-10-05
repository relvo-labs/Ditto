//! A blocking protocol 0.2 client. The token comes from the descriptor the
//! controlled launcher left open, or, in development mode only, from the
//! shared token that mode announces. A `dittoctl` run from a terminal has no
//! launcher token and cannot connect; its rescue commands work offline instead.

use std::{
    env,
    io::{self, BufRead, BufReader, Write},
    os::unix::{io::FromRawFd, io::RawFd, net::UnixStream},
    path::PathBuf,
    time::Duration,
};

use ditto_protocol::{
    rpc::{ClientInfo, HandshakeAuth, HandshakeInput, RpcError, RpcRequest, RpcResponse},
    ErrorName, RequestMeta, LAUNCHER_KIND_ENV, LAUNCHER_SOCKET_ENV, LAUNCHER_TOKEN_FD_ENV,
    LAUNCHER_VERSION_ENV, PROTOCOL_VERSION,
};
use serde_json::{json, Value};

pub fn launcher_token() -> io::Result<String> {
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
            "no launcher token: start this client from Core, use development mode, or use --offline for rescue",
        )
    })
}

pub fn socket_path() -> io::Result<PathBuf> {
    Ok(match env::var_os(LAUNCHER_SOCKET_ENV) {
        Some(path) => PathBuf::from(path),
        None => match env::var_os("DITTO_RUNTIME_DIR") {
            Some(directory) => PathBuf::from(directory).join("core.sock"),
            None => PathBuf::from(env::var_os("XDG_RUNTIME_DIR").ok_or_else(|| {
                io::Error::new(io::ErrorKind::NotFound, "XDG_RUNTIME_DIR is required")
            })?)
            .join("ditto/core.sock"),
        },
    })
}

pub struct Client {
    stream: UnixStream,
    reader: BufReader<UnixStream>,
    next_id: u64,
    pub handshake: Value,
    /// Notifications received while waiting for a response.
    pub events: Vec<Value>,
}

#[derive(Debug)]
pub struct Failure {
    pub error: RpcError,
}

impl Failure {
    fn local(message: String) -> Self {
        Self {
            error: RpcError {
                code: ErrorName::Internal.code(),
                name: ErrorName::Internal,
                message,
                outcome: None,
                data: None,
            },
        }
    }
}

impl Client {
    pub fn connect(default_kind: &str) -> io::Result<Self> {
        let token = launcher_token()?;
        let stream = UnixStream::connect(socket_path()?)?;
        let reader = BufReader::new(stream.try_clone()?);
        let mut client = Self {
            stream,
            reader,
            next_id: 0,
            handshake: Value::Null,
            events: Vec::new(),
        };
        let handshake = client
            .request(
                "core.handshake",
                json!(HandshakeInput {
                    protocol_version: PROTOCOL_VERSION.into(),
                    client: ClientInfo {
                        kind: env::var(LAUNCHER_KIND_ENV).unwrap_or_else(|_| default_kind.into()),
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
        client.handshake = handshake;
        Ok(client)
    }

    fn send(&mut self, message: &Value) -> io::Result<()> {
        serde_json::to_writer(&mut self.stream, message)?;
        self.stream.write_all(b"\n")
    }

    pub fn read_message(&mut self) -> io::Result<Value> {
        let mut line = String::new();
        if self.reader.read_line(&mut line)? == 0 {
            return Err(io::Error::new(
                io::ErrorKind::UnexpectedEof,
                "core closed the connection",
            ));
        }
        Ok(serde_json::from_str(&line)?)
    }

    pub fn set_read_timeout(&mut self, timeout: Option<Duration>) -> io::Result<()> {
        self.stream.set_read_timeout(timeout)
    }

    pub fn request(&mut self, method: &str, params: Value) -> Result<Value, Failure> {
        self.next_id += 1;
        let id = format!("ctl-{}", self.next_id);
        let body = RpcRequest {
            jsonrpc: "2.0".into(),
            id: Some(id.clone()),
            method: method.into(),
            params,
        };
        let sent = self.send(&json!(body)).and_then(|()| loop {
            let message = self.read_message()?;
            if message.get("id").and_then(Value::as_str) == Some(id.as_str())
                && message.get("method").is_none()
            {
                return Ok(message);
            }
            if message.get("method").is_some() {
                self.events.push(message);
            }
        });
        let message = sent.map_err(|error| Failure::local(error.to_string()))?;
        let response: RpcResponse = serde_json::from_value(message)
            .map_err(|error| Failure::local(format!("malformed response: {error}")))?;
        match (response.result, response.error) {
            (Some(result), _) => Ok(result),
            (None, Some(error)) => Err(Failure { error }),
            (None, None) => Err(Failure::local(
                "response carried neither result nor error".into(),
            )),
        }
    }

    pub fn capability(
        &mut self,
        capability_id: &str,
        params: Value,
        operation_id: Option<&str>,
        deadline_ms: u64,
    ) -> Result<Value, Failure> {
        let mut params = if params.is_null() { json!({}) } else { params };
        params["_meta"] = json!(RequestMeta {
            protocol_version: PROTOCOL_VERSION.into(),
            operation_id: operation_id.map(String::from),
            deadline_ms: Some(deadline_ms),
            on_behalf_of: None,
        });
        self.request(capability_id, params)
    }
}
