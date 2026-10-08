//! System integration on Core's side (G1-CORE-17): the desktop-entry index
//! and application launch, the `org.freedesktop.Notifications` server, and
//! logind. It lives beside Core, not in the Shell or hostd: a replaceable
//! launcher must not rebuild the index, a Shell restart must not drop the bus
//! name, and rescue mode (no Node) must still show notifications.
//!
//! Core depends on the [`SystemServices`] trait only; `fake` is the in-memory
//! implementation the Core tests use, [`real::RealSystem`] the one a session
//! runs.

#[cfg(feature = "dbus")]
mod dbus;
pub mod desktop_entry;
pub mod fake;
pub mod index;
pub mod launch;
pub mod notify;
pub mod real;
pub mod secrets;
mod time;
mod watch;

pub use launch::LaunchOptions;
pub use real::{RealSystem, RealSystemConfig};

use ditto_protocol::services::{
    AppEntry, LauncherAppsOutput, LauncherLaunchInput, LauncherLaunchOutput, NotificationItem,
    PolicyDecision, SessionState, Urgency,
};

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SystemError {
    /// The component (D-Bus, logind, systemd user manager) is not reachable.
    Unavailable(String),
    NotFound(String),
    Invalid(String),
    Failed(String),
}

pub type SystemResult<T> = Result<T, SystemError>;

/// What the notification server asks Core for each incoming notification.
/// Core answers from the `svc.notification_policy` provider with a 50 ms
/// deadline; `None` means the policy was not reachable, and the server then
/// **shows** the notification and marks it `policy_unavailable`.
pub trait NotificationHooks: Send + Sync {
    fn decide(&self, app_name: &str, urgency: Urgency) -> Option<(PolicyDecision, Option<String>)>;
    fn posted(&self, notification: &NotificationItem);
    fn closed(&self, id: u32, reason: &str);
}

/// Session signals from logind.
pub trait SessionHooks: Send + Sync {
    fn lock_requested(&self);
    fn unlock_requested(&self);
    fn preparing_for_sleep(&self, before: bool);
}

pub trait SystemServices: Send + Sync {
    /// Fuzzy search over the desktop-entry index (name, generic name,
    /// keywords, app id); hidden and `NoDisplay` entries excluded.
    fn search_apps(&self, query: &str, limit: usize) -> SystemResult<LauncherAppsOutput>;
    fn list_apps(&self, category: Option<&str>) -> SystemResult<LauncherAppsOutput>;
    fn app(&self, app_id: &str) -> SystemResult<AppEntry>;
    /// Start an application in its own transient user scope
    /// (`app-ditto-<app>-<rand>.scope`), so no Ditto process is its parent;
    /// `open_uri` resolves the default application with `xdg-mime`.
    fn launch(
        &self,
        input: &LauncherLaunchInput,
        operation_id: &str,
    ) -> SystemResult<LauncherLaunchOutput>;

    fn notifications(&self, limit: usize) -> SystemResult<Vec<NotificationItem>>;
    fn dismiss(&self, id: u32) -> SystemResult<bool>;
    /// Whether this process owns `org.freedesktop.Notifications`.
    fn notification_server_owned(&self) -> bool;
    fn set_notification_hooks(&self, hooks: std::sync::Arc<dyn NotificationHooks>);
    /// A notification from Ditto itself (app name `Ditto`), stored and
    /// published like any other so the notification area shows it. The
    /// default has nowhere to put it and says so.
    fn post_notification(
        &self,
        _summary: &str,
        _body: &str,
        _urgency: Urgency,
    ) -> SystemResult<NotificationItem> {
        unavailable()
    }

    fn session_state(&self) -> SystemResult<SessionState>;
    fn lock_session(&self) -> SystemResult<()>;
    fn logout(&self) -> SystemResult<()>;
    fn suspend(&self) -> SystemResult<()>;
    fn poweroff(&self) -> SystemResult<()>;
    fn set_session_hooks(&self, hooks: std::sync::Arc<dyn SessionHooks>);
    /// Core reports whether its lock client runs, for `session.state`.
    fn set_lock_state(&self, locked: bool, client_running: bool);

    /// `launcher`, `notifications`, `logind`: for catalog availability.
    fn component_available(&self, component: &str) -> bool;
}

/// Used when no real system integration is available (no session bus, a
/// test fixture Core): every action says it is unavailable instead of
/// pretending to have happened.
pub struct UnavailableSystem;

fn unavailable<T>() -> SystemResult<T> {
    Err(SystemError::Unavailable(
        "system integration is not running".into(),
    ))
}

impl SystemServices for UnavailableSystem {
    fn search_apps(&self, _query: &str, _limit: usize) -> SystemResult<LauncherAppsOutput> {
        unavailable()
    }
    fn list_apps(&self, _category: Option<&str>) -> SystemResult<LauncherAppsOutput> {
        unavailable()
    }
    fn app(&self, _app_id: &str) -> SystemResult<AppEntry> {
        unavailable()
    }
    fn launch(
        &self,
        _input: &LauncherLaunchInput,
        _operation_id: &str,
    ) -> SystemResult<LauncherLaunchOutput> {
        unavailable()
    }
    fn notifications(&self, _limit: usize) -> SystemResult<Vec<NotificationItem>> {
        Ok(vec![])
    }
    fn dismiss(&self, _id: u32) -> SystemResult<bool> {
        Ok(false)
    }
    fn notification_server_owned(&self) -> bool {
        false
    }
    fn set_notification_hooks(&self, _hooks: std::sync::Arc<dyn NotificationHooks>) {}
    fn session_state(&self) -> SystemResult<SessionState> {
        unavailable()
    }
    fn lock_session(&self) -> SystemResult<()> {
        unavailable()
    }
    fn logout(&self) -> SystemResult<()> {
        unavailable()
    }
    fn suspend(&self) -> SystemResult<()> {
        unavailable()
    }
    fn poweroff(&self) -> SystemResult<()> {
        unavailable()
    }
    fn set_session_hooks(&self, _hooks: std::sync::Arc<dyn SessionHooks>) {}
    fn set_lock_state(&self, _locked: bool, _client_running: bool) {}
    fn component_available(&self, _component: &str) -> bool {
        false
    }
}
