use std::fmt;

/// What a caller can act on. `StorageFull` and `Io` are distinguished because
/// the product says "not enough space, nothing was changed" for the first and
/// the head and the protected revision stay intact in both.
#[derive(Debug)]
pub enum StoreError {
    StorageFull,
    Io(String),
    Corrupt(String),
    Locked,
    NotFound(String),
    Conflict(String),
    Invalid(String),
    Sqlite(rusqlite::Error),
}

pub type StoreResult<T> = Result<T, StoreError>;

impl fmt::Display for StoreError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::StorageFull => write!(formatter, "storage full"),
            Self::Io(reason) => write!(formatter, "storage I/O error: {reason}"),
            Self::Corrupt(reason) => write!(formatter, "database integrity check failed: {reason}"),
            Self::Locked => write!(formatter, "another writer holds the database lock"),
            Self::NotFound(what) => write!(formatter, "not found: {what}"),
            Self::Conflict(what) => write!(formatter, "conflict: {what}"),
            Self::Invalid(what) => write!(formatter, "invalid: {what}"),
            Self::Sqlite(error) => write!(formatter, "sqlite: {error}"),
        }
    }
}

impl std::error::Error for StoreError {}

impl From<rusqlite::Error> for StoreError {
    fn from(error: rusqlite::Error) -> Self {
        if let rusqlite::Error::SqliteFailure(failure, message) = &error {
            match failure.code {
                rusqlite::ErrorCode::DiskFull => return Self::StorageFull,
                rusqlite::ErrorCode::SystemIoFailure => {
                    return Self::Io(message.clone().unwrap_or_else(|| "SQLITE_IOERR".into()))
                }
                rusqlite::ErrorCode::DatabaseCorrupt | rusqlite::ErrorCode::NotADatabase => {
                    return Self::Corrupt(message.clone().unwrap_or_default())
                }
                rusqlite::ErrorCode::DatabaseBusy | rusqlite::ErrorCode::DatabaseLocked => {
                    return Self::Locked
                }
                rusqlite::ErrorCode::ConstraintViolation => {
                    return Self::Conflict(message.clone().unwrap_or_else(|| "constraint".into()))
                }
                _ => {}
            }
        }
        Self::Sqlite(error)
    }
}

impl From<std::io::Error> for StoreError {
    fn from(error: std::io::Error) -> Self {
        if error.raw_os_error() == Some(libc::ENOSPC) {
            return Self::StorageFull;
        }
        Self::Io(error.to_string())
    }
}

impl From<serde_json::Error> for StoreError {
    fn from(error: serde_json::Error) -> Self {
        Self::Invalid(error.to_string())
    }
}
