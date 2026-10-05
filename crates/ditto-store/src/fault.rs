//! Test-only storage faults. With the `fault-injection` feature, a test (or
//! `DITTO_FAULT=store.write:ioerr[:n]` read by Core's fault layer) can make the
//! next writes fail the way SQLite reports `SQLITE_IOERR` or `SQLITE_FULL`.
//! Without the feature these functions are empty and the points do not exist.

use crate::error::StoreResult;

#[cfg(feature = "fault-injection")]
mod armed {
    use std::sync::Mutex;

    use crate::error::StoreError;

    #[derive(Clone, Copy, Debug, PartialEq, Eq)]
    pub enum Kind {
        IoErr,
        Full,
    }

    #[derive(Clone, Copy, Debug)]
    pub enum Point {
        BeforeWrite,
        BeforeCommit,
        /// In a package unpack, after extraction and before the rename.
        Unpack,
    }

    static ARMED: Mutex<Option<(Point, Kind, u32)>> = Mutex::new(None);

    pub fn arm(point: Point, kind: Kind, count: u32) {
        *ARMED.lock().expect("fault state") = Some((point, kind, count));
    }

    pub fn disarm() {
        *ARMED.lock().expect("fault state") = None;
    }

    pub fn fire(at: Point) -> Result<(), StoreError> {
        let mut armed = ARMED.lock().expect("fault state");
        let Some((point, kind, remaining)) = *armed else {
            return Ok(());
        };
        if std::mem::discriminant(&point) != std::mem::discriminant(&at) {
            return Ok(());
        }
        *armed = (remaining > 1).then_some((point, kind, remaining - 1));
        Err(match kind {
            Kind::IoErr => StoreError::Io("injected SQLITE_IOERR".into()),
            Kind::Full => StoreError::StorageFull,
        })
    }
}

#[cfg(feature = "fault-injection")]
pub use armed::{arm, disarm, Kind, Point};

pub(crate) fn before_write() -> StoreResult<()> {
    #[cfg(feature = "fault-injection")]
    armed::fire(armed::Point::BeforeWrite)?;
    Ok(())
}

pub(crate) fn before_commit() -> StoreResult<()> {
    #[cfg(feature = "fault-injection")]
    armed::fire(armed::Point::BeforeCommit)?;
    Ok(())
}

pub(crate) fn during_unpack() -> StoreResult<()> {
    #[cfg(feature = "fault-injection")]
    armed::fire(armed::Point::Unpack)?;
    Ok(())
}
