//! Core's authoritative store: SQLite, migrations, the revision lineage,
//! snapshots and the package index. It is a library so `dittoctl --offline`
//! can use the same code, under the same lock, when Core cannot start.

pub mod approvals;
pub mod audit;
pub mod bindings;
pub mod changes;
pub mod conversations;
pub mod error;
pub mod fault;
pub mod grants;
pub mod jobs;
pub mod lock;
pub mod packages;
pub mod preferences;
pub mod profiles;
pub mod rescue;
pub mod retention;
pub mod schema;
pub mod time;
pub mod turns;

use std::path::{Path, PathBuf};

use rusqlite::{Connection, OpenFlags, Transaction};

pub use error::{StoreError, StoreResult};
pub use lock::WriterLock;

/// Refuse a commit when less than this is free: the check makes a failure
/// early and explainable; the transaction itself is what protects the head.
pub const MIN_FREE_BYTES: u64 = 64 * 1024 * 1024;

#[derive(Clone, Debug)]
pub struct Paths {
    pub data: PathBuf,
    pub state: PathBuf,
    pub cache: PathBuf,
}

impl Paths {
    /// `$XDG_DATA_HOME/ditto`, `$XDG_STATE_HOME/ditto`, `$XDG_CACHE_HOME/ditto`.
    /// `DITTO_DATA_DIR` overrides all three as subdirectories, for fixtures
    /// and tests that must not touch the logged-in session's store.
    pub fn from_environment() -> StoreResult<Self> {
        if let Some(root) = std::env::var_os("DITTO_DATA_DIR") {
            let root = PathBuf::from(root);
            return Ok(Self::under(&root));
        }
        let home = std::env::var_os("HOME")
            .map(PathBuf::from)
            .ok_or_else(|| StoreError::Invalid("HOME is not set".into()))?;
        let xdg = |name: &str, fallback: &str| {
            std::env::var_os(name)
                .map(PathBuf::from)
                .filter(|path| path.is_absolute())
                .unwrap_or_else(|| home.join(fallback))
                .join("ditto")
        };
        Ok(Self {
            data: xdg("XDG_DATA_HOME", ".local/share"),
            state: xdg("XDG_STATE_HOME", ".local/state"),
            cache: xdg("XDG_CACHE_HOME", ".cache"),
        })
    }

    pub fn under(root: &Path) -> Self {
        Self {
            data: root.join("data"),
            state: root.join("state"),
            cache: root.join("cache"),
        }
    }

    pub fn database(&self) -> PathBuf {
        self.data.join("core.db")
    }

    pub fn lock(&self) -> PathBuf {
        self.data.join("core.lock")
    }

    pub fn packages(&self) -> PathBuf {
        self.data.join("packages")
    }

    pub fn package_dir(&self, sha256: &str) -> PathBuf {
        self.packages().join("sha256").join(sha256)
    }

    pub fn staging(&self) -> PathBuf {
        self.packages().join(".staging")
    }

    pub fn plugin_data(&self, plugin_id: &str) -> PathBuf {
        self.data.join("plugin-data").join(plugin_id)
    }

    pub fn snapshots(&self) -> PathBuf {
        self.data.join("snapshots")
    }

    pub fn backups(&self) -> PathBuf {
        self.state.join("backups")
    }

    pub fn app_index(&self) -> PathBuf {
        self.cache.join("app-index.db")
    }

    pub fn create(&self) -> StoreResult<()> {
        for directory in [
            &self.data,
            &self.state,
            &self.cache,
            &self.packages(),
            &self.snapshots(),
            &self.backups(),
        ] {
            std::fs::create_dir_all(directory)?;
            set_mode(directory, 0o700)?;
        }
        Ok(())
    }
}

fn set_mode(path: &Path, mode: u32) -> StoreResult<()> {
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(mode))?;
    Ok(())
}

/// What happened when the store opened; recorded in the audit log by Core.
#[derive(Clone, Debug, Default)]
pub struct OpenReport {
    pub migrated_from: Option<u32>,
    pub backup: Option<PathBuf>,
    pub removed_partials: Vec<PathBuf>,
}

pub struct Store {
    connection: Connection,
    paths: Paths,
    writable: bool,
}

impl Store {
    /// The writer: holds `lock`, runs `quick_check`, backs up then migrates,
    /// and clears `.partial` leftovers of interrupted snapshot or package
    /// writes. Only one exists at a time across all processes.
    pub fn open_writer(paths: &Paths, _lock: &WriterLock) -> StoreResult<(Self, OpenReport)> {
        paths.create()?;
        let database = paths.database();
        let existed = database.exists();
        let mut connection = Connection::open(&database)?;
        set_mode(&database, 0o600)?;
        schema::configure(&connection)?;
        let mut report = OpenReport::default();
        if existed {
            schema::quick_check(&connection)?;
            let version = schema::user_version(&connection)?;
            if version < schema::CURRENT_VERSION {
                report.backup = Some(backup(&connection, paths, version)?);
            }
        }
        let from = schema::migrate(&mut connection)?;
        if from != schema::CURRENT_VERSION {
            report.migrated_from = Some(from);
        }
        report.removed_partials = remove_partials(paths)?;
        Ok((
            Self {
                connection,
                paths: paths.clone(),
                writable: true,
            },
            report,
        ))
    }

    /// A read-only connection for queries that must not queue behind a long
    /// transaction. Fails if the database has not been created yet.
    pub fn open_reader(paths: &Paths) -> StoreResult<Self> {
        let connection = Connection::open_with_flags(
            paths.database(),
            OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
        )?;
        connection.busy_timeout(std::time::Duration::from_millis(2_000))?;
        connection.pragma_update(None, "query_only", "ON")?;
        if schema::user_version(&connection)? != schema::CURRENT_VERSION {
            return Err(StoreError::Invalid("database schema is not current".into()));
        }
        Ok(Self {
            connection,
            paths: paths.clone(),
            writable: false,
        })
    }

    pub fn paths(&self) -> &Paths {
        &self.paths
    }

    pub fn connection(&self) -> &Connection {
        &self.connection
    }

    /// Run `work` in one immediate transaction. Anything it returns as an
    /// error, including `SQLITE_FULL` and `SQLITE_IOERR`, rolls back all of it.
    pub fn write<T>(
        &mut self,
        work: impl FnOnce(&Transaction<'_>) -> StoreResult<T>,
    ) -> StoreResult<T> {
        if !self.writable {
            return Err(StoreError::Invalid("read-only store".into()));
        }
        fault::before_write()?;
        let transaction = self
            .connection
            .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        let value = work(&transaction)?;
        fault::before_commit()?;
        transaction.commit()?;
        Ok(value)
    }

    /// Free bytes on the file system holding the database.
    pub fn free_bytes(&self) -> StoreResult<u64> {
        free_bytes(&self.paths.data)
    }
}

pub fn free_bytes(path: &Path) -> StoreResult<u64> {
    use std::os::unix::ffi::OsStrExt;
    let path = std::ffi::CString::new(path.as_os_str().as_bytes())
        .map_err(|_| StoreError::Invalid("path contains NUL".into()))?;
    // SAFETY: stat is a valid writable statvfs and path is NUL-terminated.
    let mut stat: libc::statvfs = unsafe { std::mem::zeroed() };
    if unsafe { libc::statvfs(path.as_ptr(), &mut stat) } != 0 {
        return Err(std::io::Error::last_os_error().into());
    }
    Ok(stat.f_bavail * stat.f_frsize)
}

fn backup(connection: &Connection, paths: &Paths, version: u32) -> StoreResult<PathBuf> {
    std::fs::create_dir_all(paths.backups())?;
    let stamp = time::now().replace(':', "");
    let target = paths.backups().join(format!("core-{version}-{stamp}.db"));
    let mut destination = Connection::open(&target)?;
    {
        let backup = rusqlite::backup::Backup::new(connection, &mut destination)?;
        backup.run_to_completion(64, std::time::Duration::from_millis(5), None)?;
    }
    drop(destination);
    set_mode(&target, 0o600)?;
    std::fs::File::open(&target)?.sync_all()?;
    std::fs::File::open(paths.backups())?.sync_all()?;
    // Keep the three most recent backups.
    let mut existing: Vec<PathBuf> = std::fs::read_dir(paths.backups())?
        .filter_map(|entry| entry.ok().map(|entry| entry.path()))
        .filter(|path| {
            path.file_name()
                .and_then(|name| name.to_str())
                .is_some_and(|name| name.starts_with("core-") && name.ends_with(".db"))
        })
        .collect();
    existing.sort();
    while existing.len() > 3 {
        std::fs::remove_file(existing.remove(0))?;
    }
    std::fs::File::open(paths.backups())?.sync_all()?;
    Ok(target)
}

fn remove_partials(paths: &Paths) -> StoreResult<Vec<PathBuf>> {
    let mut removed = Vec::new();
    for directory in [paths.snapshots(), paths.staging()] {
        let Ok(entries) = std::fs::read_dir(&directory) else {
            continue;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            let partial = path
                .file_name()
                .and_then(|name| name.to_str())
                .is_some_and(|name| name.ends_with(".partial"))
                || directory == paths.staging();
            if partial {
                if path.is_dir() {
                    std::fs::remove_dir_all(&path)?;
                } else {
                    std::fs::remove_file(&path)?;
                }
                removed.push(path);
            }
        }
    }
    Ok(removed)
}

#[cfg(test)]
pub(crate) mod testing {
    use super::*;

    pub struct TempStore {
        pub store: Store,
        pub root: PathBuf,
        _lock: WriterLock,
    }

    impl Drop for TempStore {
        fn drop(&mut self) {
            let _ = crate::packages::make_writable(&self.root);
            let _ = std::fs::remove_dir_all(&self.root);
        }
    }

    pub fn temp_root(label: &str) -> PathBuf {
        let root = std::env::temp_dir().join(format!(
            "ditto-store-{label}-{}-{}",
            std::process::id(),
            ditto_protocol::ids::ulid()
        ));
        std::fs::create_dir_all(&root).unwrap();
        root
    }

    pub fn open(label: &str) -> TempStore {
        let root = temp_root(label);
        let paths = Paths::under(&root);
        let lock = WriterLock::acquire(&paths.lock()).unwrap();
        let (store, _) = Store::open_writer(&paths, &lock).unwrap();
        TempStore {
            store,
            root,
            _lock: lock,
        }
    }
}
