//! In-memory system services for tests and for a Core running without a
//! session bus. It never pretends an action happened on the real system:
//! `launch` records the request, the session actions only change its state.

use std::sync::{Arc, Mutex};

use ditto_protocol::services::{
    AppEntry, LauncherAppsOutput, LauncherLaunchInput, LauncherLaunchOutput, NotificationItem,
    PolicyDecision, SessionState, Urgency,
};

use crate::{NotificationHooks, SessionHooks, SystemError, SystemResult, SystemServices};

#[derive(Default)]
struct State {
    apps: Vec<AppEntry>,
    launched: Vec<LauncherLaunchInput>,
    notifications: Vec<NotificationItem>,
    next_id: u32,
    session: Option<SessionState>,
    power_actions: Vec<String>,
    notification_hooks: Option<Arc<dyn NotificationHooks>>,
    session_hooks: Option<Arc<dyn SessionHooks>>,
}

#[derive(Default)]
pub struct FakeSystem {
    state: Mutex<State>,
}

impl FakeSystem {
    pub fn with_apps(apps: Vec<AppEntry>) -> Self {
        let system = Self::default();
        system.state.lock().expect("fake system").apps = apps;
        system
    }

    pub fn sample_apps() -> Vec<AppEntry> {
        let app = |id: &str, name: &str, category: &str| AppEntry {
            app_id: id.into(),
            name: name.into(),
            generic_name: None,
            icon: None,
            categories: vec![category.into()],
            keywords: vec![],
        };
        vec![
            app("firefox", "Firefox", "Network"),
            app("foot", "Foot", "System"),
            app("org.kde.kate", "Kate", "Utility"),
        ]
    }

    pub fn launched(&self) -> Vec<LauncherLaunchInput> {
        self.state.lock().expect("fake system").launched.clone()
    }

    pub fn power_actions(&self) -> Vec<String> {
        self.state
            .lock()
            .expect("fake system")
            .power_actions
            .clone()
    }

    /// Deliver a notification the way the D-Bus server would.
    pub fn notify(&self, app_name: &str, summary: &str, urgency: Urgency) -> NotificationItem {
        let hooks = self
            .state
            .lock()
            .expect("fake system")
            .notification_hooks
            .clone();
        let decision = hooks
            .as_ref()
            .and_then(|hooks| hooks.decide(app_name, urgency));
        let mut state = self.state.lock().expect("fake system");
        state.next_id += 1;
        let item = NotificationItem {
            id: state.next_id,
            app_name: app_name.into(),
            summary: summary.into(),
            body: String::new(),
            urgency,
            decision: decision
                .as_ref()
                .map_or(PolicyDecision::Show, |(decision, _)| *decision),
            policy_unavailable: decision.is_none(),
            merged_count: 0,
            created_at: "1970-01-01T00:00:00.000Z".into(),
        };
        state.notifications.push(item.clone());
        drop(state);
        if let Some(hooks) = hooks {
            hooks.posted(&item);
        }
        item
    }

    pub fn signal_lock(&self) {
        let hooks = self
            .state
            .lock()
            .expect("fake system")
            .session_hooks
            .clone();
        if let Some(hooks) = hooks {
            hooks.lock_requested();
        }
    }
}

fn matches(app: &AppEntry, query: &str) -> bool {
    let query = query.to_lowercase();
    app.name.to_lowercase().contains(&query)
        || app.app_id.to_lowercase().contains(&query)
        || app
            .keywords
            .iter()
            .any(|keyword| keyword.to_lowercase().contains(&query))
}

impl SystemServices for FakeSystem {
    fn search_apps(&self, query: &str, limit: usize) -> SystemResult<LauncherAppsOutput> {
        let state = self.state.lock().expect("fake system");
        Ok(LauncherAppsOutput {
            apps: state
                .apps
                .iter()
                .filter(|app| matches(app, query))
                .take(limit)
                .cloned()
                .collect(),
            indexed_at: None,
        })
    }

    fn list_apps(&self, category: Option<&str>) -> SystemResult<LauncherAppsOutput> {
        let state = self.state.lock().expect("fake system");
        Ok(LauncherAppsOutput {
            apps: state
                .apps
                .iter()
                .filter(|app| {
                    category.is_none_or(|category| app.categories.iter().any(|c| c == category))
                })
                .cloned()
                .collect(),
            indexed_at: None,
        })
    }

    fn app(&self, app_id: &str) -> SystemResult<AppEntry> {
        self.state
            .lock()
            .expect("fake system")
            .apps
            .iter()
            .find(|app| app.app_id == app_id)
            .cloned()
            .ok_or_else(|| SystemError::NotFound(format!("no application {app_id}")))
    }

    fn launch(
        &self,
        input: &LauncherLaunchInput,
        operation_id: &str,
    ) -> SystemResult<LauncherLaunchOutput> {
        let app_id = match (&input.app_id, &input.open_uri) {
            (Some(app_id), _) => self.app(app_id)?.app_id,
            (None, Some(_)) => "default-handler".into(),
            (None, None) => {
                return Err(SystemError::Invalid(
                    "app_id or open_uri is required".into(),
                ))
            }
        };
        self.state
            .lock()
            .expect("fake system")
            .launched
            .push(input.clone());
        Ok(LauncherLaunchOutput {
            accepted: true,
            operation_id: operation_id.into(),
            unit: format!("app-ditto-{app_id}-fake.scope"),
            app_id,
        })
    }

    fn notifications(&self, limit: usize) -> SystemResult<Vec<NotificationItem>> {
        let state = self.state.lock().expect("fake system");
        Ok(state
            .notifications
            .iter()
            .rev()
            .take(limit)
            .cloned()
            .collect())
    }

    fn post_notification(
        &self,
        summary: &str,
        body: &str,
        urgency: Urgency,
    ) -> SystemResult<NotificationItem> {
        let mut item = self.notify("Ditto", summary, urgency);
        let mut state = self.state.lock().expect("fake system");
        if let Some(stored) = state
            .notifications
            .iter_mut()
            .find(|stored| stored.id == item.id)
        {
            stored.body = body.into();
        }
        item.body = body.into();
        Ok(item)
    }

    fn dismiss(&self, id: u32) -> SystemResult<bool> {
        let mut state = self.state.lock().expect("fake system");
        let before = state.notifications.len();
        state.notifications.retain(|item| item.id != id);
        Ok(state.notifications.len() != before)
    }

    fn notification_server_owned(&self) -> bool {
        false
    }

    fn set_notification_hooks(&self, hooks: Arc<dyn NotificationHooks>) {
        self.state.lock().expect("fake system").notification_hooks = Some(hooks);
    }

    fn session_state(&self) -> SystemResult<SessionState> {
        Ok(self
            .state
            .lock()
            .expect("fake system")
            .session
            .clone()
            .unwrap_or(SessionState {
                locked: false,
                lock_client_running: false,
                preparing_for_sleep: false,
                logind_available: false,
            }))
    }

    fn lock_session(&self) -> SystemResult<()> {
        self.state
            .lock()
            .expect("fake system")
            .power_actions
            .push("lock".into());
        Ok(())
    }

    fn logout(&self) -> SystemResult<()> {
        self.state
            .lock()
            .expect("fake system")
            .power_actions
            .push("logout".into());
        Ok(())
    }

    fn suspend(&self) -> SystemResult<()> {
        self.state
            .lock()
            .expect("fake system")
            .power_actions
            .push("suspend".into());
        Ok(())
    }

    fn poweroff(&self) -> SystemResult<()> {
        self.state
            .lock()
            .expect("fake system")
            .power_actions
            .push("poweroff".into());
        Ok(())
    }

    fn set_session_hooks(&self, hooks: Arc<dyn SessionHooks>) {
        self.state.lock().expect("fake system").session_hooks = Some(hooks);
    }

    fn set_lock_state(&self, locked: bool, client_running: bool) {
        let mut state = self.state.lock().expect("fake system");
        let mut session = state.session.clone().unwrap_or(SessionState {
            locked: false,
            lock_client_running: false,
            preparing_for_sleep: false,
            logind_available: false,
        });
        session.locked = locked;
        session.lock_client_running = client_running;
        state.session = Some(session);
    }

    fn component_available(&self, component: &str) -> bool {
        component == "launcher"
    }
}
