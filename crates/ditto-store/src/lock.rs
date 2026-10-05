//! The single-writer lock. The authority is this library plus `core.lock`,
//! not a process: Core holds the lock while it runs, and `dittoctl --offline`
//! can open the database for writing only when it gets the same lock.

use std::{fs::File, os::fd::AsRawFd, path::Path};

use crate::error::{StoreError, StoreResult};

pub struct WriterLock {
    _file: File,
}

impl WriterLock {
    /// Non-blocking: a second writer is refused, never queued behind the
    /// first, so rescue learns immediately that Core is still running.
    pub fn acquire(path: &Path) -> StoreResult<Self> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let file = std::fs::OpenOptions::new()
            .create(true)
            .truncate(false)
            .write(true)
            .open(path)?;
        // SAFETY: flock on a valid descriptor has no memory preconditions.
        let result = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) };
        if result != 0 {
            let error = std::io::Error::last_os_error();
            if error.raw_os_error() == Some(libc::EWOULDBLOCK) {
                return Err(StoreError::Locked);
            }
            return Err(error.into());
        }
        Ok(Self { _file: file })
    }
}
