//! The two D-Bus parts: the `org.freedesktop.Notifications` server on the
//! session bus (Desktop Notifications Specification 1.2) and the logind
//! session on the system bus. Both use zbus' blocking API; its executor
//! thread runs the interface methods, so a `Notify` call must return within
//! [`crate::notify::POLICY_BOUND`] plus bookkeeping.

use std::collections::HashMap;
use std::sync::Arc;

use ditto_protocol::services::Urgency;
use zbus::blocking::{Connection, MessageIterator};
use zbus::fdo::{RequestNameFlags, RequestNameReply};
use zbus::message::Type as MessageType;
use zbus::object_server::SignalEmitter;
use zbus::zvariant::{OwnedObjectPath, OwnedValue};
use zbus::MatchRule;

use crate::notify::Incoming;
use crate::real::Shared;

pub const NOTIFICATIONS_NAME: &str = "org.freedesktop.Notifications";
pub const NOTIFICATIONS_PATH: &str = "/org/freedesktop/Notifications";

/// `NotificationClosed` reasons from the specification.
pub const CLOSED_DISMISSED: u32 = 2;
pub const CLOSED_BY_CALL: u32 = 3;

struct Server {
    shared: Arc<Shared>,
}

fn urgency_of(hints: &HashMap<String, OwnedValue>) -> Urgency {
    // The spec says BYTE; some clients send an integer type instead.
    let value = hints.get("urgency").and_then(|value| {
        u8::try_from(value)
            .ok()
            .map(i64::from)
            .or_else(|| i32::try_from(value).ok().map(i64::from))
            .or_else(|| u32::try_from(value).ok().map(i64::from))
    });
    match value {
        Some(0) => Urgency::Low,
        Some(2) => Urgency::Critical,
        _ => Urgency::Normal,
    }
}

#[zbus::interface(name = "org.freedesktop.Notifications")]
impl Server {
    #[allow(clippy::too_many_arguments)]
    async fn notify(
        &self,
        app_name: String,
        replaces_id: u32,
        _app_icon: String,
        summary: String,
        body: String,
        _actions: Vec<String>,
        hints: HashMap<String, OwnedValue>,
        _expire_timeout: i32,
    ) -> u32 {
        let urgency = urgency_of(&hints);
        self.shared
            .ingest(Incoming {
                app_name,
                replaces_id,
                summary,
                body,
                urgency,
            })
            .id
    }

    async fn close_notification(
        &self,
        id: u32,
        #[zbus(signal_emitter)] emitter: SignalEmitter<'_>,
    ) -> zbus::fdo::Result<()> {
        if self.shared.forget(id, "closed_by_call") {
            Self::notification_closed(&emitter, id, CLOSED_BY_CALL).await?;
        }
        Ok(())
    }

    /// No `actions`: the Shell does not invoke actions yet, and advertising
    /// them would make clients wait for an `ActionInvoked` that never comes.
    fn get_capabilities(&self) -> Vec<String> {
        vec!["body".into(), "persistence".into()]
    }

    #[zbus(out_args("name", "vendor", "version", "spec_version"))]
    fn get_server_information(&self) -> (String, String, String, String) {
        (
            "Ditto".into(),
            "Ditto".into(),
            env!("CARGO_PKG_VERSION").into(),
            "1.2".into(),
        )
    }

    #[zbus(signal)]
    async fn notification_closed(
        emitter: &SignalEmitter<'_>,
        id: u32,
        reason: u32,
    ) -> zbus::Result<()>;
}

/// Serve and take the name without queueing or replacing: if another daemon
/// owns it, it keeps it and this reports why.
pub fn start_notifications(shared: Arc<Shared>) -> Result<Connection, String> {
    let connection = zbus::blocking::connection::Builder::session()
        .and_then(|builder| builder.serve_at(NOTIFICATIONS_PATH, Server { shared }))
        .and_then(|builder| builder.build())
        .map_err(|error| format!("session bus: {error}"))?;
    match connection
        .request_name_with_flags(NOTIFICATIONS_NAME, RequestNameFlags::DoNotQueue.into())
    {
        Ok(RequestNameReply::PrimaryOwner | RequestNameReply::AlreadyOwner) => Ok(connection),
        Ok(RequestNameReply::Exists | RequestNameReply::InQueue) => {
            Err(format!("{NOTIFICATIONS_NAME} is owned by another process"))
        }
        Err(error) => Err(format!("requesting {NOTIFICATIONS_NAME}: {error}")),
    }
}

pub fn emit_closed(connection: &Connection, id: u32, reason: u32) {
    let _ = connection.emit_signal(
        None::<&str>,
        NOTIFICATIONS_PATH,
        NOTIFICATIONS_NAME,
        "NotificationClosed",
        &(id, reason),
    );
}

#[zbus::proxy(
    interface = "org.freedesktop.login1.Manager",
    default_service = "org.freedesktop.login1",
    default_path = "/org/freedesktop/login1",
    gen_async = false,
    blocking_name = "Login1Manager"
)]
trait Manager {
    fn get_session(&self, session_id: &str) -> zbus::Result<OwnedObjectPath>;
    #[zbus(name = "GetSessionByPID")]
    fn get_session_by_pid(&self, pid: u32) -> zbus::Result<OwnedObjectPath>;
    fn suspend(&self, interactive: bool) -> zbus::Result<()>;
    fn power_off(&self, interactive: bool) -> zbus::Result<()>;
}

#[zbus::proxy(
    interface = "org.freedesktop.login1.Session",
    default_service = "org.freedesktop.login1",
    gen_async = false,
    blocking_name = "Login1Session"
)]
trait Session {
    fn lock(&self) -> zbus::Result<()>;
    fn terminate(&self) -> zbus::Result<()>;
}

pub struct Logind {
    connection: Connection,
    session: OwnedObjectPath,
}

impl Logind {
    /// The session this desktop runs in. Under `ditto-core.service` the
    /// process is not inside a logind session, so `GetSessionByPID` alone
    /// would fail: `XDG_SESSION_ID` (imported by the login script) comes first,
    /// then `auto` (logind falls back to the user's display session).
    pub fn connect() -> Result<Self, String> {
        let connection = Connection::system().map_err(|error| format!("system bus: {error}"))?;
        let manager =
            Login1Manager::new(&connection).map_err(|error| format!("logind: {error}"))?;
        let mut tried = Vec::new();
        let mut session = None;
        if let Ok(id) = std::env::var("XDG_SESSION_ID") {
            match manager.get_session(&id) {
                Ok(path) => session = Some(path),
                Err(error) => tried.push(format!("GetSession({id}): {error}")),
            }
        }
        if session.is_none() {
            match manager.get_session("auto") {
                Ok(path) => session = Some(path),
                Err(error) => tried.push(format!("GetSession(auto): {error}")),
            }
        }
        if session.is_none() {
            match manager.get_session_by_pid(std::process::id()) {
                Ok(path) => session = Some(path),
                Err(error) => tried.push(format!("GetSessionByPID: {error}")),
            }
        }
        let session = session.ok_or_else(|| format!("no logind session: {}", tried.join("; ")))?;
        Ok(Self {
            connection,
            session,
        })
    }

    pub fn session_path(&self) -> &str {
        self.session.as_str()
    }

    fn session_proxy(&self) -> zbus::Result<Login1Session<'_>> {
        Login1Session::builder(&self.connection)
            .path(self.session.clone())?
            .build()
    }

    pub fn lock(&self) -> zbus::Result<()> {
        self.session_proxy()?.lock()
    }

    pub fn terminate(&self) -> zbus::Result<()> {
        self.session_proxy()?.terminate()
    }

    pub fn suspend(&self) -> zbus::Result<()> {
        Login1Manager::new(&self.connection)?.suspend(false)
    }

    pub fn power_off(&self) -> zbus::Result<()> {
        Login1Manager::new(&self.connection)?.power_off(false)
    }

    /// Two threads, each blocked on its own match rule until a signal
    /// arrives: `Lock`/`Unlock` on this session and `PrepareForSleep`.
    pub fn listen(&self, shared: Arc<Shared>) -> Result<(), String> {
        let session_rule = MatchRule::builder()
            .msg_type(MessageType::Signal)
            .sender("org.freedesktop.login1")
            .and_then(|b| b.interface("org.freedesktop.login1.Session"))
            .and_then(|b| b.path(self.session.clone()))
            .map(|b| b.build())
            .map_err(|error| error.to_string())?;
        let sleep_rule = MatchRule::builder()
            .msg_type(MessageType::Signal)
            .sender("org.freedesktop.login1")
            .and_then(|b| b.interface("org.freedesktop.login1.Manager"))
            .and_then(|b| b.member("PrepareForSleep"))
            .map(|b| b.build())
            .map_err(|error| error.to_string())?;
        let session_messages =
            MessageIterator::for_match_rule(session_rule, &self.connection, Some(16))
                .map_err(|error| error.to_string())?;
        let sleep_messages =
            MessageIterator::for_match_rule(sleep_rule, &self.connection, Some(16))
                .map_err(|error| error.to_string())?;
        let for_session = shared.clone();
        std::thread::Builder::new()
            .name("ditto-logind-session".into())
            .spawn(move || {
                for message in session_messages.flatten() {
                    let header = message.header();
                    match header.member().map(|member| member.as_str()) {
                        Some("Lock") => for_session.session_signal(|hooks| hooks.lock_requested()),
                        Some("Unlock") => {
                            for_session.session_signal(|hooks| hooks.unlock_requested())
                        }
                        _ => {}
                    }
                }
            })
            .map_err(|error| error.to_string())?;
        std::thread::Builder::new()
            .name("ditto-logind-sleep".into())
            .spawn(move || {
                for message in sleep_messages.flatten() {
                    if let Ok(before) = message.body().deserialize::<bool>() {
                        shared.preparing_for_sleep(before);
                    }
                }
            })
            .map_err(|error| error.to_string())?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use zbus::zvariant::Value;

    #[test]
    fn urgency_hint_accepts_byte_and_integers() {
        let hints = |value: Value<'static>| {
            HashMap::from([("urgency".to_string(), OwnedValue::try_from(value).unwrap())])
        };
        assert_eq!(urgency_of(&hints(Value::U8(0))), Urgency::Low);
        assert_eq!(urgency_of(&hints(Value::U8(2))), Urgency::Critical);
        assert_eq!(urgency_of(&hints(Value::I32(2))), Urgency::Critical);
        assert_eq!(urgency_of(&hints(Value::U8(1))), Urgency::Normal);
        assert_eq!(urgency_of(&HashMap::new()), Urgency::Normal);
    }
}
