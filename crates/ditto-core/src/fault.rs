//! Fault injection for tests (G1-QA-04). Compiled only with the
//! `fault-injection` feature; a release build contains neither the points nor
//! the code that reads `DITTO_FAULT`, which CI checks on the binaries.
//!
//! `DITTO_FAULT=<point>:<action>[:<n>]`, for example
//! `coordinator.after_state=applying:abort_process:1` or
//! `store.write:ioerr:1`.

#[cfg(feature = "fault-injection")]
mod enabled {
    use std::sync::Mutex;

    pub const AFTER_PREPARED: &str = "coordinator.after_state=prepared";
    pub const AFTER_APPLYING: &str = "coordinator.after_state=applying";
    pub const AFTER_VERIFYING: &str = "coordinator.after_state=verifying";
    pub const READBACK_MISMATCH: &str = "coordinator.readback=mismatch";
    pub const STORE_WRITE: &str = "store.write";

    static ARMED: Mutex<Option<(String, String, u32)>> = Mutex::new(None);

    pub fn load_from_environment() {
        let Ok(text) = std::env::var("DITTO_FAULT") else {
            return;
        };
        let mut parts = text.rsplitn(3, ':').collect::<Vec<_>>();
        parts.reverse();
        let (point, action, count) = match parts.as_slice() {
            [point, action, count] if count.parse::<u32>().is_ok() => (
                point.to_string(),
                action.to_string(),
                count.parse().unwrap_or(1),
            ),
            [point, action, more] => (format!("{point}:{action}"), more.to_string(), 1),
            [point, action] => (point.to_string(), action.to_string(), 1),
            _ => return,
        };
        if point == STORE_WRITE {
            let kind = if action == "full" {
                ditto_store::fault::Kind::Full
            } else {
                ditto_store::fault::Kind::IoErr
            };
            ditto_store::fault::arm(ditto_store::fault::Point::BeforeCommit, kind, count);
            return;
        }
        *ARMED.lock().expect("fault state") = Some((point, action, count));
    }

    /// `store.commit_revision:ioerr|full` and `store.unpack:ioerr` fire at the
    /// moment named, not at the first store write after start (boot writes
    /// would otherwise take the fault).
    fn arm_store(point: &str, store_point: ditto_store::fault::Point) {
        if let Some(action) = take(point) {
            let kind = if action == "full" {
                ditto_store::fault::Kind::Full
            } else {
                ditto_store::fault::Kind::IoErr
            };
            ditto_store::fault::arm(store_point, kind, 1);
        }
    }

    pub fn before_commit_revision() {
        arm_store(
            "store.commit_revision",
            ditto_store::fault::Point::BeforeCommit,
        );
    }

    pub fn before_unpack() {
        arm_store("store.unpack", ditto_store::fault::Point::Unpack);
    }

    pub fn arm(point: &str, action: &str, count: u32) {
        *ARMED.lock().expect("fault state") = Some((point.into(), action.into(), count));
    }

    /// The action armed for `point`, consuming one use.
    pub fn take(point: &str) -> Option<String> {
        let mut armed = ARMED.lock().expect("fault state");
        let (armed_point, action, count) = armed.clone()?;
        if armed_point != point {
            return None;
        }
        *armed = (count > 1).then(|| (armed_point, action.clone(), count - 1));
        Some(action)
    }

    /// `abort_process` ends Core the way a crash does (SIGKILL semantics:
    /// no destructors, no final writes).
    pub fn hit(point: &str) {
        if let Some(action) = take(point) {
            if action == "abort_process" {
                crate::log::event("fault.abort_process", &[("point", point)]);
                // SAFETY: raising SIGKILL on ourselves has no preconditions.
                unsafe { libc::kill(libc::getpid(), libc::SIGKILL) };
            }
        }
    }
}

#[cfg(feature = "fault-injection")]
pub use enabled::*;

#[cfg(not(feature = "fault-injection"))]
pub fn load_from_environment() {}

#[cfg(not(feature = "fault-injection"))]
#[inline(always)]
pub fn hit(_point: &str) {}

#[cfg(not(feature = "fault-injection"))]
#[inline(always)]
pub fn take(_point: &str) -> Option<String> {
    None
}

#[cfg(not(feature = "fault-injection"))]
#[inline(always)]
pub fn before_commit_revision() {}

#[cfg(not(feature = "fault-injection"))]
#[inline(always)]
pub fn before_unpack() {}
