//! Process-wide state shared by every connection: the compositor adapter, the
//! observation event broker and the subscriber sinks. The compositor owns the
//! truth; the snapshot kept here is a projection rebuilt from the compositor
//! after every change and after every reconnect, never a persistent cache.

use std::{
    collections::{BTreeSet, HashMap},
    sync::{
        atomic::{AtomicBool, Ordering},
        mpsc::Sender,
        Mutex,
    },
};

use ditto_compositor::{AdapterError, AdapterResult, CompositorAdapter, EventSource};
use ditto_protocol::{
    catalog::Availability,
    rpc::{RpcRequest, RpcResponse},
    DesktopEventNotification, DesktopEventPayload, DesktopSnapshot, EventTopic, Window,
};

use crate::events::{Delivery, EventBroker, Registration};

pub const EVENT_QUEUE_CAPACITY: usize = 1024;

#[derive(Clone, Debug)]
pub enum Outgoing {
    Response(Box<RpcResponse>),
    Event(Box<DesktopEventNotification>),
    /// A request or notification Core itself sends to the client
    /// (`participant.*`, `host.invoke`, `shell.command`).
    Request(Box<RpcRequest>),
}

pub struct Session {
    adapter: Mutex<Box<dyn CompositorAdapter>>,
    broker: Mutex<EventBroker>,
    sinks: Mutex<HashMap<String, Sender<Outgoing>>>,
    online: AtomicBool,
    offline_reason: Mutex<Option<String>>,
    shortcut_handler: Mutex<Option<ditto_compositor::ShortcutHandler>>,
    outputs_removed: Mutex<Option<OutputsRemoved>>,
    windows_opened: Mutex<Option<WindowsOpened>>,
}

/// Called with windows that appeared since the last snapshot (Core applies
/// the Profile's region rules to them, D-40).
pub type WindowsOpened = std::sync::Arc<dyn Fn(Vec<Window>) + Send + Sync>;

/// Called after outputs disappeared, with their names and the windows as
/// they were before (Core's window rescue, plan/03/05 §7).
pub type OutputsRemoved = std::sync::Arc<dyn Fn(Vec<String>, Vec<Window>) + Send + Sync>;

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
            shortcut_handler: Mutex::new(None),
            outputs_removed: Mutex::new(None),
            windows_opened: Mutex::new(None),
        }
    }

    /// Who is told when an output goes away; Core sets it once at start.
    pub fn set_windows_opened(&self, hook: WindowsOpened) {
        *self.windows_opened.lock().expect("windows hook") = Some(hook);
    }

    pub fn set_outputs_removed(&self, hook: OutputsRemoved) {
        *self.outputs_removed.lock().expect("outputs hook") = Some(hook);
    }

    /// Where pressed global shortcuts go; kept across compositor reconnects.
    pub fn set_shortcut_handler(&self, handler: ditto_compositor::ShortcutHandler) {
        *self.shortcut_handler.lock().expect("shortcut handler") = Some(handler.clone());
        self.adapter
            .lock()
            .expect("adapter lock")
            .set_shortcut_handler(handler);
    }

    pub fn compositor_label(&self) -> String {
        self.adapter.lock().expect("adapter lock").label()
    }

    /// Observation sequence reported to callers as `observed_seq`.
    pub fn observed_seq(&self) -> u64 {
        self.broker.lock().expect("broker lock").seq()
    }

    pub fn profile_revision(&self) -> Option<String> {
        self.broker.lock().expect("broker lock").profile_revision()
    }

    pub fn set_profile_revision(&self, revision: Option<String>) {
        self.broker
            .lock()
            .expect("broker lock")
            .set_profile_revision(revision);
    }

    /// Publish a non-desktop event (changes, plugins, notifications, tasks).
    pub fn publish_event(&self, payload: DesktopEventPayload) {
        self.broker
            .lock()
            .expect("broker lock")
            .publish_event(payload);
        self.flush();
    }

    pub fn require_resync(&self, subscription_id: &str, reason: &str) {
        self.broker
            .lock()
            .expect("broker lock")
            .require_resync(subscription_id, reason);
        self.flush();
    }

    pub fn subscription_count(&self) -> usize {
        self.broker
            .lock()
            .expect("broker lock")
            .subscription_count()
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
        self.subscribe_topics(after_seq, [EventTopic::Desktop].into_iter().collect(), sink)
    }

    pub fn subscribe_topics(
        &self,
        after_seq: Option<u64>,
        topics: BTreeSet<EventTopic>,
        sink: Sender<Outgoing>,
    ) -> Registration {
        let registration = self
            .broker
            .lock()
            .expect("broker lock")
            .register_topics(after_seq, topics);
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
        let removed = {
            let mut broker = self.broker.lock().expect("broker lock");
            let changes = difference(broker.snapshot(), &observed);
            if changes.is_empty() {
                return;
            }
            let vanished: Vec<String> = changes
                .iter()
                .filter_map(|payload| match payload {
                    DesktopEventPayload::OutputRemoved { output_name } => Some(output_name.clone()),
                    _ => None,
                })
                .collect();
            let before = (!vanished.is_empty()).then(|| broker.snapshot().windows.clone());
            let opened: Vec<Window> = observed
                .windows
                .iter()
                .filter(|w| {
                    !broker
                        .snapshot()
                        .windows
                        .iter()
                        .any(|known| known.id == w.id)
                })
                .cloned()
                .collect();
            for payload in changes {
                broker.publish(payload, observed.clone());
            }
            (before.map(|windows| (vanished, windows)), opened)
        };
        let (removed, opened) = removed;
        self.flush();
        if !opened.is_empty() {
            let hook = self.windows_opened.lock().expect("windows hook").clone();
            if let Some(hook) = hook {
                hook(opened);
            }
        }
        if let Some((vanished, windows)) = removed {
            let hook = self.outputs_removed.lock().expect("outputs hook").clone();
            if let Some(hook) = hook {
                hook(vanished, windows);
            }
        }
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
        if let Some(handler) = self
            .shortcut_handler
            .lock()
            .expect("shortcut handler")
            .clone()
        {
            adapter.set_shortcut_handler(handler);
        }
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
                Delivery::ResyncRequired(event) => (vec![*event], true),
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
///
/// The stream is read on its own thread and never waits for a re-read: a
/// compositor drops an IPC client whose socket stays full (Wayfire's
/// "Error sending json to client!"), and a burst of operations produces events
/// faster than one full snapshot re-read each. Every change already received
/// is covered by a single re-read, since `publish_changes` re-reads the whole
/// snapshot and publishes the difference.
pub fn pump(session: &Session, source: &mut dyn EventSource) {
    let (sender, receiver) = std::sync::mpsc::channel();
    std::thread::scope(|scope| {
        scope.spawn(move || loop {
            let next = source.next_change();
            let last = !matches!(next, Ok(Some(_)));
            if sender.send(next).is_err() || last {
                return;
            }
        });
        while let Ok(first) = receiver.recv() {
            let mut next = Some(first);
            while let Some(item) = next.take() {
                match item {
                    Ok(Some(_)) => next = receiver.try_recv().ok(),
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
            session.publish_changes();
        }
    });
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

    /// A compositor drops an IPC client whose socket stays full, so the event
    /// stream must keep being read while a re-read waits (here: for the
    /// adapter, which the test holds). Before, one event was read per re-read.
    #[test]
    fn the_event_stream_is_drained_while_a_re_read_waits() {
        use ditto_compositor::CompositorChange;
        use std::sync::{atomic::AtomicUsize, Arc};
        use std::time::{Duration, Instant};

        struct Burst {
            left: usize,
            read: Arc<AtomicUsize>,
        }
        impl EventSource for Burst {
            fn next_change(&mut self) -> AdapterResult<Option<CompositorChange>> {
                if self.left == 0 {
                    return Ok(None);
                }
                self.left -= 1;
                self.read.fetch_add(1, Ordering::SeqCst);
                Ok(Some(CompositorChange::Windows))
            }
        }

        let (compositor, _events) = FixtureCompositor::paired();
        let session = Arc::new(Session::new(Box::new(compositor)));
        let (held, holding) = mpsc::channel();
        let (release, released) = mpsc::channel::<()>();
        let holder = {
            let session = Arc::clone(&session);
            std::thread::spawn(move || {
                session.with_adapter(|_| {
                    held.send(()).unwrap();
                    released.recv().unwrap();
                    Ok(())
                })
            })
        };
        holding.recv().unwrap();
        let read = Arc::new(AtomicUsize::new(0));
        let pumping = {
            let session = Arc::clone(&session);
            let read = Arc::clone(&read);
            std::thread::spawn(move || pump(&session, &mut Burst { left: 500, read }))
        };
        let deadline = Instant::now() + Duration::from_secs(5);
        while read.load(Ordering::SeqCst) < 500 && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(5));
        }
        let drained = read.load(Ordering::SeqCst);
        release.send(()).unwrap();
        holder.join().unwrap().unwrap();
        pumping.join().unwrap();
        assert_eq!(
            drained, 500,
            "the stream was read while the adapter was held"
        );
        assert!(
            !session.is_online(),
            "the end of the stream takes the session offline"
        );
    }

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
