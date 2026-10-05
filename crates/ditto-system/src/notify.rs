//! Notification bookkeeping, independent of D-Bus so the policy and merge
//! rules are testable without a bus. The server in `dbus.rs` feeds it.

use std::collections::VecDeque;
use std::sync::mpsc::{self, SyncSender, TrySendError};
use std::sync::{Arc, RwLock};
use std::time::{Duration, SystemTime};

use ditto_protocol::services::{NotificationItem, PolicyDecision, Urgency};

use crate::NotificationHooks;

/// History kept in memory; older notifications are dropped silently. The
/// list is the notification area's history, not a store of record.
pub const CAPACITY: usize = 200;
/// Longest a `Notify` call waits for the policy. Core already bounds its own
/// call at 50 ms; this bound holds even if the hook ignores its deadline.
pub const POLICY_BOUND: Duration = Duration::from_millis(100);

pub type Decision = Option<(PolicyDecision, Option<String>)>;

struct Ask {
    app_name: String,
    urgency: Urgency,
    hooks: Arc<dyn NotificationHooks>,
    reply: mpsc::Sender<Decision>,
}

/// One worker thread asks the hook, so a hook that blocks delays only the
/// policy answer, never the D-Bus reply beyond [`POLICY_BOUND`]. The queue is
/// small: when it is full the policy is treated as unavailable at once.
pub struct Policy {
    hooks: RwLock<Option<Arc<dyn NotificationHooks>>>,
    sender: SyncSender<Ask>,
}

impl Default for Policy {
    fn default() -> Self {
        Self::new()
    }
}

impl Policy {
    pub fn new() -> Self {
        let (sender, receiver) = mpsc::sync_channel::<Ask>(8);
        // The thread sleeps in recv() until a notification arrives.
        let _ = std::thread::Builder::new()
            .name("ditto-notify-policy".into())
            .spawn(move || {
                for ask in receiver {
                    let _ = ask.reply.send(ask.hooks.decide(&ask.app_name, ask.urgency));
                }
            });
        Self {
            hooks: RwLock::new(None),
            sender,
        }
    }

    pub fn set_hooks(&self, hooks: Arc<dyn NotificationHooks>) {
        *self.hooks.write().expect("policy hooks") = Some(hooks);
    }

    pub fn hooks(&self) -> Option<Arc<dyn NotificationHooks>> {
        self.hooks.read().expect("policy hooks").clone()
    }

    pub fn ask(&self, app_name: &str, urgency: Urgency) -> Decision {
        let hooks = self.hooks()?;
        let (reply, answer) = mpsc::channel();
        let ask = Ask {
            app_name: app_name.into(),
            urgency,
            hooks,
            reply,
        };
        match self.sender.try_send(ask) {
            Ok(()) => {}
            Err(TrySendError::Full(_) | TrySendError::Disconnected(_)) => return None,
        }
        // Timeout or a dead worker: the policy is unavailable.
        answer.recv_timeout(POLICY_BOUND).unwrap_or_default()
    }
}

#[derive(Clone, Debug)]
pub struct Incoming {
    pub app_name: String,
    pub replaces_id: u32,
    pub summary: String,
    pub body: String,
    pub urgency: Urgency,
}

#[derive(Default)]
pub struct Store {
    items: VecDeque<NotificationItem>,
    last_id: u32,
}

impl Store {
    fn next_id(&mut self) -> u32 {
        loop {
            self.last_id = self.last_id.wrapping_add(1);
            if self.last_id != 0 && !self.items.iter().any(|item| item.id == self.last_id) {
                return self.last_id;
            }
        }
    }

    /// Record one notification under `decision` and return what was stored.
    /// `None` (policy unreachable) shows it and says so; critical urgency is
    /// always shown, whatever the policy said. `replaces_id` updates in
    /// place; `merge` folds it into the newest notification of the same app.
    pub fn apply(
        &mut self,
        incoming: Incoming,
        decision: Decision,
        now: SystemTime,
    ) -> NotificationItem {
        let policy_unavailable = decision.is_none();
        let mut decision = decision.map_or(PolicyDecision::Show, |(decision, _)| decision);
        if incoming.urgency == Urgency::Critical {
            decision = PolicyDecision::Show;
        }
        let created_at = crate::time::rfc3339(now);
        let target = if incoming.replaces_id != 0 {
            self.items
                .iter()
                .position(|item| item.id == incoming.replaces_id)
        } else if decision == PolicyDecision::Merge {
            self.items
                .iter()
                .rposition(|item| item.app_name == incoming.app_name)
        } else {
            None
        };
        if let Some(index) = target {
            let mut item = self.items.remove(index).expect("index from position");
            if incoming.replaces_id == 0 {
                item.merged_count += 1;
            }
            item.summary = incoming.summary;
            item.body = incoming.body;
            item.urgency = incoming.urgency;
            item.decision = decision;
            item.policy_unavailable = policy_unavailable;
            item.created_at = created_at;
            self.items.push_back(item.clone());
            return item;
        }
        let item = NotificationItem {
            id: self.next_id(),
            app_name: incoming.app_name,
            summary: incoming.summary,
            body: incoming.body,
            urgency: incoming.urgency,
            decision,
            policy_unavailable,
            merged_count: 0,
            created_at,
        };
        self.items.push_back(item.clone());
        while self.items.len() > CAPACITY {
            self.items.pop_front();
        }
        item
    }

    pub fn remove(&mut self, id: u32) -> bool {
        let before = self.items.len();
        self.items.retain(|item| item.id != id);
        self.items.len() != before
    }

    pub fn list(&self, limit: usize) -> Vec<NotificationItem> {
        self.items.iter().rev().take(limit).cloned().collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    fn incoming(app: &str, summary: &str, urgency: Urgency) -> Incoming {
        Incoming {
            app_name: app.into(),
            replaces_id: 0,
            summary: summary.into(),
            body: String::new(),
            urgency,
        }
    }

    #[test]
    fn unavailable_policy_shows_and_says_so() {
        let mut store = Store::default();
        let item = store.apply(
            incoming("mail", "a", Urgency::Normal),
            None,
            SystemTime::UNIX_EPOCH,
        );
        assert_eq!(item.decision, PolicyDecision::Show);
        assert!(item.policy_unavailable);
        assert_eq!(item.id, 1);
        assert_eq!(item.created_at, "1970-01-01T00:00:00.000Z");
    }

    #[test]
    fn critical_is_always_shown() {
        let mut store = Store::default();
        let item = store.apply(
            incoming("battery", "low", Urgency::Critical),
            Some((PolicyDecision::Silence, Some("quiet-hours".into()))),
            SystemTime::now(),
        );
        assert_eq!(item.decision, PolicyDecision::Show);
        assert!(!item.policy_unavailable);
    }

    #[test]
    fn merge_folds_into_the_newest_of_the_same_app() {
        let mut store = Store::default();
        let merge = Some((PolicyDecision::Merge, None));
        let first = store.apply(
            incoming("chat", "one", Urgency::Normal),
            merge.clone(),
            SystemTime::now(),
        );
        store.apply(
            incoming("mail", "x", Urgency::Normal),
            None,
            SystemTime::now(),
        );
        let merged = store.apply(
            incoming("chat", "two", Urgency::Normal),
            merge.clone(),
            SystemTime::now(),
        );
        assert_eq!(merged.id, first.id);
        assert_eq!(merged.merged_count, 1);
        assert_eq!(merged.summary, "two");
        assert_eq!(
            store
                .list(10)
                .iter()
                .map(|i| i.summary.as_str())
                .collect::<Vec<_>>(),
            ["two", "x"]
        );
        // Merge with nothing to merge into creates a new one.
        let lone = store.apply(incoming("new", "n", Urgency::Low), merge, SystemTime::now());
        assert_eq!(lone.merged_count, 0);
        assert_eq!(store.list(10).len(), 3);
    }

    #[test]
    fn replaces_id_updates_in_place_and_capacity_bounds_history() {
        let mut store = Store::default();
        let first = store.apply(incoming("dl", "10%", Urgency::Low), None, SystemTime::now());
        let mut update = incoming("dl", "90%", Urgency::Low);
        update.replaces_id = first.id;
        let updated = store.apply(
            update,
            Some((PolicyDecision::Silence, None)),
            SystemTime::now(),
        );
        assert_eq!(updated.id, first.id);
        assert_eq!(updated.merged_count, 0);
        assert_eq!(updated.decision, PolicyDecision::Silence);
        for n in 0..CAPACITY + 5 {
            store.apply(
                incoming("spam", &n.to_string(), Urgency::Low),
                None,
                SystemTime::now(),
            );
        }
        assert_eq!(store.list(usize::MAX).len(), CAPACITY);
        assert!(store.remove(store.list(1)[0].id));
        assert!(!store.remove(0));
    }

    struct Hooks {
        delay: Duration,
        decision: PolicyDecision,
        posted: Mutex<u32>,
    }

    impl NotificationHooks for Hooks {
        fn decide(&self, _: &str, _: Urgency) -> Option<(PolicyDecision, Option<String>)> {
            std::thread::sleep(self.delay);
            Some((self.decision, Some("rule".into())))
        }
        fn posted(&self, _: &NotificationItem) {
            *self.posted.lock().unwrap() += 1;
        }
        fn closed(&self, _: u32, _: &str) {}
    }

    #[test]
    fn policy_answers_within_its_bound() {
        let policy = Policy::new();
        assert_eq!(policy.ask("a", Urgency::Normal), None, "no hooks yet");
        policy.set_hooks(Arc::new(Hooks {
            delay: Duration::ZERO,
            decision: PolicyDecision::Silence,
            posted: Mutex::new(0),
        }));
        assert_eq!(
            policy.ask("a", Urgency::Normal),
            Some((PolicyDecision::Silence, Some("rule".into())))
        );
        policy.set_hooks(Arc::new(Hooks {
            delay: Duration::from_millis(400),
            decision: PolicyDecision::Merge,
            posted: Mutex::new(0),
        }));
        let started = std::time::Instant::now();
        assert_eq!(policy.ask("a", Urgency::Normal), None);
        assert!(
            started.elapsed() < Duration::from_millis(250),
            "took {:?}",
            started.elapsed()
        );
    }
}
