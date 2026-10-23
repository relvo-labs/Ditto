//! In-memory event stream. The compositor owns desktop truth and Core's store
//! owns configuration; this broker keeps a bounded replay window and
//! per-subscriber queues, never a persistent state. Every topic shares one
//! `seq`; each notification also names the previous `seq` delivered to its
//! subscription, so a consumer of some topics still detects a lost event.

use std::collections::{BTreeSet, HashMap, VecDeque};

use ditto_protocol::{DesktopEventNotification, DesktopEventPayload, DesktopSnapshot, EventTopic};

#[derive(Clone, Debug)]
struct Recorded {
    seq: u64,
    profile_revision: Option<String>,
    payload: DesktopEventPayload,
}

#[derive(Debug)]
struct Subscriber {
    /// Each queued event with the `seq` of the one before it in this
    /// subscription, so the chain has no gaps even though `seq` does.
    pending: VecDeque<(Recorded, u64)>,
    /// Why this subscription must restart, once it must.
    resync: Option<String>,
    topics: BTreeSet<EventTopic>,
    last: u64,
}

impl Subscriber {
    fn wants(&self, payload: &DesktopEventPayload) -> bool {
        payload
            .topic()
            .is_none_or(|topic| self.topics.contains(&topic))
    }
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
    ResyncRequired(Box<DesktopEventNotification>),
}

pub struct EventBroker {
    seq: u64,
    profile_revision: Option<String>,
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
            profile_revision: None,
            next_subscription: 0,
            capacity,
            snapshot,
            history: VecDeque::new(),
            subscribers: HashMap::new(),
        }
    }

    pub fn publish(&mut self, payload: DesktopEventPayload, observed_snapshot: DesktopSnapshot) {
        self.snapshot = observed_snapshot;
        self.publish_event(payload);
    }

    /// Publish an event that does not change the desktop snapshot.
    pub fn publish_event(&mut self, payload: DesktopEventPayload) {
        self.seq = self.seq.checked_add(1).expect("event sequence exhausted");
        let event = Recorded {
            seq: self.seq,
            profile_revision: self.profile_revision.clone(),
            payload,
        };
        self.history.push_back(event.clone());
        if self.history.len() > self.capacity {
            self.history.pop_front();
        }
        for subscriber in self.subscribers.values_mut() {
            if subscriber.resync.is_some() || !subscriber.wants(&event.payload) {
                continue;
            }
            if subscriber.pending.len() == self.capacity {
                subscriber.pending.clear();
                subscriber.resync = Some("queue_overflow".into());
            } else {
                subscriber
                    .pending
                    .push_back((event.clone(), subscriber.last));
                subscriber.last = event.seq;
            }
        }
    }

    pub fn register(&mut self, after_seq: Option<u64>) -> Registration {
        self.register_topics(after_seq, [EventTopic::Desktop].into_iter().collect())
    }

    pub fn register_topics(
        &mut self,
        after_seq: Option<u64>,
        topics: BTreeSet<EventTopic>,
    ) -> Registration {
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
        let subscriber = Subscriber {
            pending: VecDeque::new(),
            resync: None,
            topics,
            last: self.seq,
        };
        let replay = after_seq.map_or_else(Vec::new, |after| {
            let mut previous = after;
            self.history
                .iter()
                .filter(|event| event.seq > after && subscriber.wants(&event.payload))
                .map(|event| {
                    let notification = Self::notification(&subscription_id, event, previous);
                    previous = event.seq;
                    notification
                })
                .collect()
        });
        // Replay covers everything this subscription's topics had up to the
        // registration `seq`; the first live event links to that `seq`,
        // whichever of snapshot or replay the consumer used.
        self.subscribers.insert(subscription_id.clone(), subscriber);
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
            let previous = subscriber.last;
            self.subscribers.remove(subscription_id);
            return Some(Delivery::ResyncRequired(Box::new(
                DesktopEventNotification {
                    subscription_id: subscription_id.into(),
                    seq: self.seq,
                    prev_seq: previous,
                    profile_revision: self.profile_revision.clone(),
                    payload: DesktopEventPayload::ResyncRequired { reason },
                },
            )));
        }
        Some(Delivery::Events(
            subscriber
                .pending
                .drain(..)
                .map(|(event, previous)| Self::notification(subscription_id, &event, previous))
                .collect(),
        ))
    }

    /// The observation sequence reported as `ResultMeta.observed_seq`.
    pub fn seq(&self) -> u64 {
        self.seq
    }

    pub fn profile_revision(&self) -> Option<String> {
        self.profile_revision.clone()
    }

    pub fn set_profile_revision(&mut self, revision: Option<String>) {
        self.profile_revision = revision;
    }

    /// End one subscription with `resync_required`, for example when the
    /// grant it was established under is revoked.
    pub fn require_resync(&mut self, subscription_id: &str, reason: &str) {
        if let Some(subscriber) = self.subscribers.get_mut(subscription_id) {
            subscriber.pending.clear();
            subscriber.resync = Some(reason.to_string());
        }
    }

    pub fn subscription_count(&self) -> usize {
        self.subscribers.len()
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

    fn notification(
        subscription_id: &str,
        event: &Recorded,
        prev_seq: u64,
    ) -> DesktopEventNotification {
        DesktopEventNotification {
            subscription_id: subscription_id.into(),
            seq: event.seq,
            prev_seq,
            profile_revision: event.profile_revision.clone(),
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
        assert!(events.iter().all(|event| event.profile_revision.is_none()));
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

#[cfg(test)]
mod topic_tests {
    use super::*;

    #[test]
    fn subscribers_only_receive_their_topics_but_share_one_sequence() {
        let empty = DesktopSnapshot {
            outputs: vec![],
            workspaces: vec![],
            windows: vec![],
        };
        let mut broker = EventBroker::new(8, empty.clone());
        let Registration::Ready {
            subscription_id: desktop,
            ..
        } = broker.register(None)
        else {
            panic!()
        };
        let Registration::Ready {
            subscription_id: changes,
            ..
        } = broker.register_topics(None, [EventTopic::Changes].into_iter().collect())
        else {
            panic!()
        };
        broker.set_profile_revision(Some("rev-1".into()));
        broker.publish(
            DesktopEventPayload::WorkspaceRemoved {
                workspace_id: "1".into(),
            },
            empty,
        );
        broker.publish_event(DesktopEventPayload::ProfileChanged {
            profile_id: "prf".into(),
            head_revision: "rev-1".into(),
            active: true,
        });
        let Some(Delivery::Events(first)) = broker.drain(&desktop) else {
            panic!()
        };
        let Some(Delivery::Events(second)) = broker.drain(&changes) else {
            panic!()
        };
        assert_eq!(
            first.iter().map(|event| event.seq).collect::<Vec<_>>(),
            vec![1]
        );
        assert_eq!(
            second.iter().map(|event| event.seq).collect::<Vec<_>>(),
            vec![2]
        );
        assert_eq!(second[0].profile_revision.as_deref(), Some("rev-1"));
        // `seq` skips what the subscription did not ask for; `prev_seq` does not.
        assert_eq!(second[0].prev_seq, 0);
        broker.publish_event(DesktopEventPayload::ChangeUpdated {
            change: Box::new(ditto_protocol::change::ChangeSummary {
                change_id: "chg".into(),
                profile_id: "prf".into(),
                state: ditto_protocol::change::ChangeState::Committed,
                result: None,
                origin: ditto_protocol::change::ChangeOrigin::Cli,
                hot_swap_level: ditto_protocol::change::HotSwapLevel::Instant,
                title_key: "t".into(),
                committed_revision: None,
                confirmation: ditto_protocol::change::Confirmation::NotRequired,
                saved_only: None,
                created_at: String::new(),
                updated_at: String::new(),
            }),
        });
        let Some(Delivery::Events(third)) = broker.drain(&changes) else {
            panic!()
        };
        assert_eq!((third[0].seq, third[0].prev_seq), (3, 2));
    }
}
