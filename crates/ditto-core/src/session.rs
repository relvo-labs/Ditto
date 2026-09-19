//! Process-wide state shared by every connection: the compositor adapter, the
//! observation event broker and the subscriber sinks. The compositor owns the
//! truth; the snapshot kept here is a projection rebuilt from the compositor
//! after every change and after every reconnect, never a persistent cache.

use std::{
    collections::HashMap,
    sync::{
        atomic::{AtomicBool, Ordering},
        mpsc::Sender,
        Mutex,
    },
};

use ditto_compositor::{AdapterError, AdapterResult, CompositorAdapter, EventSource};
use ditto_protocol::{
    catalog::Availability, rpc::RpcResponse, DesktopEventNotification, DesktopEventPayload,
    DesktopSnapshot,
};

use crate::events::{Delivery, EventBroker, Registration};

pub const EVENT_QUEUE_CAPACITY: usize = 1024;

#[derive(Clone, Debug)]
pub enum Outgoing {
    Response(Box<RpcResponse>),
    Event(Box<DesktopEventNotification>),
}

pub struct Session {
    adapter: Mutex<Box<dyn CompositorAdapter>>,
    broker: Mutex<EventBroker>,
    sinks: Mutex<HashMap<String, Sender<Outgoing>>>,
    online: AtomicBool,
    offline_reason: Mutex<Option<String>>,
}

impl Session {
    pub fn new(mut adapter: Box<dyn CompositorAdapter>) -> Self {
        let (snapshot, online, reason) = match adapter.snapshot() {
            Ok(snapshot) => (snapshot, true, None),
            Err(error) => (empty_snapshot(), false, Some(format!("{error:?}"))),
        };
        Self {
            adapter: Mutex::new(adapter),
            broker: Mutex::new(EventBroker::new(EVENT_QUEUE_CAPACITY, snapshot)),
            sinks: Mutex::new(HashMap::new()),
            online: AtomicBool::new(online),
            offline_reason: Mutex::new(reason),
        }
    }

    pub fn compositor_label(&self) -> String {
        self.adapter.lock().expect("adapter lock").label()
    }

    /// Observation sequence reported to callers. G0 has no persistent Profile,
    /// so this is not a configuration revision.
    pub fn observation_revision(&self) -> u64 {
        self.broker.lock().expect("broker lock").revision()
    }

    pub fn is_online(&self) -> bool {
        self.online.load(Ordering::SeqCst)
    }

    /// Run one adapter operation. A lost compositor connection takes every
    /// dependent capability offline immediately instead of failing call by call.
    pub fn with_adapter<T>(
        &self,
        operation: impl FnOnce(&mut dyn CompositorAdapter) -> AdapterResult<T>,
    ) -> AdapterResult<T> {
        if !self.is_online() {
            let reason = self
                .offline_reason
                .lock()
                .expect("offline reason lock")
                .clone()
                .unwrap_or_else(|| "compositor connection is not established".into());
            return Err(AdapterError::Unavailable(reason));
        }
        let outcome = {
            let mut adapter = self.adapter.lock().expect("adapter lock");
            operation(adapter.as_mut())
        };
        if let Err(AdapterError::Unavailable(reason)) = &outcome {
            self.mark_offline(reason);
        }
        outcome
    }

    pub fn availability(&self, capability_id: &str, matrix_row: &str) -> Availability {
        let support = self
            .adapter
            .lock()
            .expect("adapter lock")
            .support(capability_id);
        if !self.is_online() {
            return Availability::DependsOnCompositor {
                matrix_row: matrix_row.into(),
                available: false,
                reason: Some("compositor connection is not established".into()),
                bound_to: support.bound_to,
            };
        }
        Availability::DependsOnCompositor {
            matrix_row: matrix_row.into(),
            available: support.available,
            reason: support.reason,
            bound_to: support.bound_to,
        }
    }

    pub fn subscribe(&self, after_seq: Option<u64>, sink: Sender<Outgoing>) -> Registration {
        let registration = self.broker.lock().expect("broker lock").register(after_seq);
        if let Registration::Ready {
            subscription_id, ..
        } = &registration
        {
            self.sinks
                .lock()
                .expect("sinks lock")
                .insert(subscription_id.clone(), sink);
        }
        registration
    }

    pub fn unsubscribe(&self, subscription_id: &str) {
        self.broker
            .lock()
            .expect("broker lock")
            .unregister(subscription_id);
        self.sinks
            .lock()
            .expect("sinks lock")
            .remove(subscription_id);
    }

    /// Re-read the compositor and publish the difference. Consumers rebuild
    /// state from a snapshot plus these events; compositor events themselves
    /// are never forwarded.
    pub fn publish_changes(&self) {
        let observed = match self.with_adapter(|adapter| adapter.snapshot()) {
            Ok(snapshot) => snapshot,
            Err(error) => {
                self.mark_offline(&format!("{error:?}"));
                return;
            }
        };
        {
            let mut broker = self.broker.lock().expect("broker lock");
            let changes = difference(broker.snapshot(), &observed);
            if changes.is_empty() {
                return;
            }
            for payload in changes {
                broker.publish(payload, observed.clone());
            }
        }
        self.flush();
    }

    pub fn mark_offline(&self, reason: &str) {
        if !self.online.swap(false, Ordering::SeqCst) {
            return;
        }
        *self.offline_reason.lock().expect("offline reason lock") = Some(reason.into());
        self.broker
            .lock()
            .expect("broker lock")
            .require_resync_all("compositor_connection_lost");
        self.flush();
    }

    /// Replace the compositor connection after a restart: state is re-read, and
    /// every subscriber is told to resync rather than being sent replayed events.
    pub fn reconnect(&self, mut adapter: Box<dyn CompositorAdapter>) -> AdapterResult<()> {
        let snapshot = adapter.snapshot()?;
        {
            let mut current = self.adapter.lock().expect("adapter lock");
            *current = adapter;
        }
        {
            let mut broker = self.broker.lock().expect("broker lock");
            broker.reset(snapshot);
            broker.require_resync_all("compositor_reconnected");
        }
        *self.offline_reason.lock().expect("offline reason lock") = None;
        self.online.store(true, Ordering::SeqCst);
        self.flush();
        Ok(())
    }

    fn flush(&self) {
        let ids: Vec<String> = self
            .sinks
            .lock()
            .expect("sinks lock")
            .keys()
            .cloned()
            .collect();
        for id in ids {
            let delivery = self.broker.lock().expect("broker lock").drain(&id);
            let Some(delivery) = delivery else {
                continue;
            };
            let (events, closed) = match delivery {
                Delivery::Events(events) => (events, false),
                Delivery::ResyncRequired(event) => (vec![event], true),
            };
            let mut sinks = self.sinks.lock().expect("sinks lock");
            let mut dropped = closed;
            if let Some(sink) = sinks.get(&id) {
                for event in events {
                    if sink.send(Outgoing::Event(Box::new(event))).is_err() {
                        dropped = true;
                        break;
                    }
                }
            }
            if dropped {
                sinks.remove(&id);
            }
        }
    }
}

/// Run the compositor event stream until it ends. Ending means the compositor
/// connection died, which takes dependent capabilities offline.
pub fn pump(session: &Session, source: &mut dyn EventSource) {
    loop {
        match source.next_change() {
            Ok(Some(_)) => session.publish_changes(),
            Ok(None) => {
                session.mark_offline("compositor event stream ended");
                return;
            }
            Err(error) => {
                session.mark_offline(&format!("{error:?}"));
                return;
            }
        }
    }
}

pub fn empty_snapshot() -> DesktopSnapshot {
    DesktopSnapshot {
        outputs: vec![],
        workspaces: vec![],
        windows: vec![],
    }
}

fn difference(previous: &DesktopSnapshot, observed: &DesktopSnapshot) -> Vec<DesktopEventPayload> {
    let mut changes = Vec::new();
    for window in &observed.windows {
        if !previous.windows.iter().any(|known| known == window) {
            changes.push(DesktopEventPayload::WindowUpsert {
                window: window.clone(),
            });
        }
    }
    for window in &previous.windows {
        if !observed.windows.iter().any(|known| known.id == window.id) {
            changes.push(DesktopEventPayload::WindowRemoved {
                window_id: window.id.clone(),
            });
        }
    }
    for workspace in &observed.workspaces {
        if !previous.workspaces.iter().any(|known| known == workspace) {
            changes.push(DesktopEventPayload::WorkspaceUpsert {
                workspace: workspace.clone(),
            });
        }
    }
    for workspace in &previous.workspaces {
        if !observed
            .workspaces
            .iter()
            .any(|known| known.id == workspace.id)
        {
            changes.push(DesktopEventPayload::WorkspaceRemoved {
                workspace_id: workspace.id.clone(),
            });
        }
    }
    for output in &observed.outputs {
        if !previous.outputs.iter().any(|known| known == output) {
            changes.push(DesktopEventPayload::OutputUpsert {
                output: output.clone(),
            });
        }
    }
    for output in &previous.outputs {
        if !observed
            .outputs
            .iter()
            .any(|known| known.name == output.name)
        {
            changes.push(DesktopEventPayload::OutputRemoved {
                output_name: output.name.clone(),
            });
        }
    }
    changes
}

#[cfg(test)]
mod tests {
    use super::*;
    use ditto_compositor::fixture::FixtureCompositor;
    use ditto_protocol::WindowSessionId;
    use std::sync::mpsc;

    #[test]
    fn publishes_only_what_actually_changed() {
        let (compositor, _events) = FixtureCompositor::paired();
        let session = Session::new(Box::new(compositor));
        let (sender, receiver) = mpsc::channel();
        assert!(matches!(
            session.subscribe(None, sender),
            Registration::Ready { .. }
        ));
        session.publish_changes();
        assert!(receiver.try_recv().is_err());
        session
            .with_adapter(|adapter| {
                adapter.focus_window(&WindowSessionId("fixture-window-2".into()))
            })
            .unwrap();
        session.publish_changes();
        let mut upserts = 0;
        while let Ok(Outgoing::Event(event)) = receiver.try_recv() {
            if matches!(event.payload, DesktopEventPayload::WindowUpsert { .. }) {
                upserts += 1;
            }
        }
        assert_eq!(upserts, 2, "focus moved between two windows");
    }

    #[test]
    fn a_lost_compositor_takes_capabilities_offline_and_asks_for_resync() {
        let (mut compositor, _events) = FixtureCompositor::paired();
        compositor.disconnect();
        let session = Session::new(Box::new(compositor));
        assert!(!session.is_online());
        let (sender, receiver) = mpsc::channel();
        session.subscribe(None, sender);
        session.mark_offline("compositor event stream ended");
        assert!(
            receiver.try_recv().is_err(),
            "already offline, no second notice"
        );
        let availability = session.availability("desktop.windows.list", "C-02");
        assert!(matches!(
            availability,
            Availability::DependsOnCompositor {
                available: false,
                ..
            }
        ));
    }
}
