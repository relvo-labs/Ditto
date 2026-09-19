//! In-memory observation stream. The compositor owns truth; this broker keeps a
//! bounded replay window and per-subscriber queues, never a persistent state.

use std::collections::{HashMap, VecDeque};

use ditto_protocol::{DesktopEventNotification, DesktopEventPayload, DesktopSnapshot};

#[derive(Clone, Debug)]
struct Recorded {
    seq: u64,
    revision: u64,
    payload: DesktopEventPayload,
}

#[derive(Debug)]
struct Subscriber {
    pending: VecDeque<Recorded>,
    /// Why this subscription must restart, once it must.
    resync: Option<String>,
}

pub enum Registration {
    Ready {
        subscription_id: String,
        snapshot: DesktopSnapshot,
        seq: u64,
        /// Events after the requested sequence, only if still retained. The
        /// consumer chooses the current snapshot or this incremental replay;
        /// applying both would duplicate already observed changes.
        replay: Vec<DesktopEventNotification>,
    },
    ResyncRequired,
}

pub enum Delivery {
    Events(Vec<DesktopEventNotification>),
    ResyncRequired(DesktopEventNotification),
}

pub struct EventBroker {
    seq: u64,
    revision: u64,
    next_subscription: u64,
    capacity: usize,
    snapshot: DesktopSnapshot,
    history: VecDeque<Recorded>,
    subscribers: HashMap<String, Subscriber>,
}

impl EventBroker {
    pub fn new(capacity: usize, snapshot: DesktopSnapshot) -> Self {
        assert!(capacity > 0, "event capacity must be positive");
        Self {
            seq: 0,
            revision: 0,
            next_subscription: 0,
            capacity,
            snapshot,
            history: VecDeque::new(),
            subscribers: HashMap::new(),
        }
    }

    pub fn publish(&mut self, payload: DesktopEventPayload, observed_snapshot: DesktopSnapshot) {
        self.seq = self.seq.checked_add(1).expect("event sequence exhausted");
        self.revision = self
            .revision
            .checked_add(1)
            .expect("observation revision exhausted");
        self.snapshot = observed_snapshot;
        let event = Recorded {
            seq: self.seq,
            revision: self.revision,
            payload,
        };
        self.history.push_back(event.clone());
        if self.history.len() > self.capacity {
            self.history.pop_front();
        }
        for subscriber in self.subscribers.values_mut() {
            if subscriber.resync.is_some() {
                continue;
            }
            if subscriber.pending.len() == self.capacity {
                subscriber.pending.clear();
                subscriber.resync = Some("queue_overflow".into());
            } else {
                subscriber.pending.push_back(event.clone());
            }
        }
    }

    pub fn register(&mut self, after_seq: Option<u64>) -> Registration {
        if let Some(after) = after_seq {
            if after > self.seq
                || self
                    .history
                    .front()
                    .is_some_and(|oldest| after.saturating_add(1) < oldest.seq)
            {
                return Registration::ResyncRequired;
            }
        }
        self.next_subscription = self
            .next_subscription
            .checked_add(1)
            .expect("subscription IDs exhausted");
        let subscription_id = format!("subscription-{}", self.next_subscription);
        let replay = after_seq.map_or_else(Vec::new, |after| {
            self.history
                .iter()
                .filter(|event| event.seq > after)
                .map(|event| Self::notification(&subscription_id, event))
                .collect()
        });
        self.subscribers.insert(
            subscription_id.clone(),
            Subscriber {
                pending: VecDeque::new(),
                resync: None,
            },
        );
        Registration::Ready {
            subscription_id,
            snapshot: self.snapshot.clone(),
            seq: self.seq,
            replay,
        }
    }

    pub fn drain(&mut self, subscription_id: &str) -> Option<Delivery> {
        let subscriber = self.subscribers.get_mut(subscription_id)?;
        if let Some(reason) = subscriber.resync.clone() {
            self.subscribers.remove(subscription_id);
            return Some(Delivery::ResyncRequired(DesktopEventNotification {
                subscription_id: subscription_id.into(),
                seq: self.seq,
                revision: self.revision,
                payload: DesktopEventPayload::ResyncRequired { reason },
            }));
        }
        Some(Delivery::Events(
            subscriber
                .pending
                .drain(..)
                .map(|event| Self::notification(subscription_id, &event))
                .collect(),
        ))
    }

    pub fn revision(&self) -> u64 {
        self.revision
    }

    pub fn snapshot(&self) -> &DesktopSnapshot {
        &self.snapshot
    }

    /// Replace the projection after a compositor reconnect. Sequence numbers
    /// keep increasing so a consumer can tell the gap from a missed event.
    pub fn reset(&mut self, snapshot: DesktopSnapshot) {
        self.snapshot = snapshot;
        self.history.clear();
    }

    /// Stop every subscription and ask for a fresh snapshot. Used when the
    /// compositor connection is lost or replaced: the retained window no longer
    /// describes what happened.
    pub fn require_resync_all(&mut self, reason: &str) {
        for subscriber in self.subscribers.values_mut() {
            subscriber.pending.clear();
            subscriber.resync = Some(reason.to_string());
        }
    }

    pub fn unregister(&mut self, subscription_id: &str) {
        self.subscribers.remove(subscription_id);
    }

    fn notification(subscription_id: &str, event: &Recorded) -> DesktopEventNotification {
        DesktopEventNotification {
            subscription_id: subscription_id.into(),
            seq: event.seq,
            revision: event.revision,
            payload: event.payload.clone(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn snapshot() -> DesktopSnapshot {
        DesktopSnapshot {
            outputs: vec![],
            workspaces: vec![],
            windows: vec![],
        }
    }

    fn change(index: usize) -> DesktopEventPayload {
        DesktopEventPayload::WorkspaceRemoved {
            workspace_id: index.to_string(),
        }
    }

    #[test]
    fn provides_snapshot_then_ordered_events() {
        let mut broker = EventBroker::new(4, snapshot());
        let Registration::Ready {
            subscription_id,
            seq,
            snapshot: initial,
            replay,
        } = broker.register(None)
        else {
            panic!("initial subscription failed")
        };
        assert_eq!(seq, 0);
        assert!(initial.windows.is_empty());
        assert!(replay.is_empty());
        broker.publish(change(1), snapshot());
        broker.publish(change(2), snapshot());
        let Some(Delivery::Events(events)) = broker.drain(&subscription_id) else {
            panic!("no events")
        };
        assert_eq!(
            events.iter().map(|event| event.seq).collect::<Vec<_>>(),
            vec![1, 2]
        );
        assert_eq!(
            events
                .iter()
                .map(|event| event.revision)
                .collect::<Vec<_>>(),
            vec![1, 2]
        );
    }

    #[test]
    fn replays_retained_events_and_requires_resync_after_gap() {
        let mut broker = EventBroker::new(2, snapshot());
        for index in 1..=3 {
            broker.publish(change(index), snapshot());
        }
        let Registration::Ready { replay, .. } = broker.register(Some(1)) else {
            panic!("replay should fit")
        };
        assert_eq!(
            replay.iter().map(|event| event.seq).collect::<Vec<_>>(),
            vec![2, 3]
        );
        assert!(matches!(
            broker.register(Some(0)),
            Registration::ResyncRequired
        ));
        assert!(matches!(
            broker.register(Some(4)),
            Registration::ResyncRequired
        ));
    }

    #[test]
    fn overflow_sends_resync_and_stops_subscription() {
        let mut broker = EventBroker::new(2, snapshot());
        let Registration::Ready {
            subscription_id, ..
        } = broker.register(None)
        else {
            panic!("initial subscription failed")
        };
        for index in 1..=4 {
            broker.publish(change(index), snapshot());
        }
        let Some(Delivery::ResyncRequired(event)) = broker.drain(&subscription_id) else {
            panic!("overflow was not signalled")
        };
        assert_eq!(event.seq, 4);
        assert!(matches!(
            event.payload,
            DesktopEventPayload::ResyncRequired { .. }
        ));
        assert!(broker.drain(&subscription_id).is_none());
    }
}
