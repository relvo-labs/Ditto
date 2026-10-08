//! Schema and migrations. `PRAGMA user_version` is the schema version;
//! migrations only move forward, each inside one transaction, after a backup.
//! A failed migration rolls back and Core starts in rescue mode instead of
//! continuing on a partly migrated database.

use ditto_protocol::change::ChangeState;
use rusqlite::{Connection, Transaction};

use crate::error::{StoreError, StoreResult};

pub const CURRENT_VERSION: u32 = 2;

const V1: &str = r#"
CREATE TABLE core_meta (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

CREATE TABLE plugin_packages (
    package_id       TEXT NOT NULL,
    version          TEXT NOT NULL,
    sha256           TEXT NOT NULL,
    tree_sha256      TEXT NOT NULL,
    source           TEXT NOT NULL,
    manifest_json    TEXT NOT NULL,
    installed_at     TEXT NOT NULL,
    installed_by_job TEXT,
    PRIMARY KEY (package_id, version)
);

CREATE TABLE profiles (
    profile_id      TEXT PRIMARY KEY,
    name            TEXT NOT NULL,
    head_revision   TEXT NOT NULL REFERENCES revisions(revision_id) DEFERRABLE INITIALLY DEFERRED,
    last_known_good TEXT REFERENCES revisions(revision_id) DEFERRABLE INITIALLY DEFERRED,
    created_at      TEXT NOT NULL,
    updated_at      TEXT NOT NULL,
    deleted_at      TEXT
);

CREATE TABLE revisions (
    revision_id     TEXT PRIMARY KEY,
    profile_id      TEXT NOT NULL REFERENCES profiles(profile_id) DEFERRABLE INITIALLY DEFERRED,
    -- No foreign key: retention may remove an old parent of a kept revision;
    -- the lineage then simply starts at the oldest retained revision.
    parent          TEXT,
    document_json   TEXT NOT NULL,
    document_sha256 TEXT NOT NULL,
    origin_kind     TEXT NOT NULL,
    origin_json     TEXT NOT NULL,
    change_id       TEXT,
    created_at      TEXT NOT NULL
);
CREATE INDEX revisions_by_profile ON revisions(profile_id, created_at);

-- Mutable facts about an immutable revision live beside it, not in it.
CREATE TABLE revision_flags (
    revision_id          TEXT PRIMARY KEY REFERENCES revisions(revision_id) ON DELETE CASCADE,
    pending_confirmation INTEGER NOT NULL DEFAULT 0,
    unstable             INTEGER NOT NULL DEFAULT 0,
    observed_until       TEXT
);

-- Entries per revision, denormalized so package references can be counted.
CREATE TABLE plugin_instances (
    entry_id         TEXT NOT NULL,
    profile_revision TEXT NOT NULL REFERENCES revisions(revision_id) ON DELETE CASCADE,
    package_id       TEXT NOT NULL,
    version          TEXT NOT NULL,
    host_kind        TEXT NOT NULL,
    config_json      TEXT NOT NULL,
    disabled         INTEGER NOT NULL,
    PRIMARY KEY (entry_id, profile_revision)
);
CREATE INDEX plugin_instances_by_package ON plugin_instances(package_id, version);

CREATE TABLE capability_bindings (
    binding_id      INTEGER PRIMARY KEY,
    slot            TEXT,
    entry_id        TEXT NOT NULL,
    capability_id   TEXT NOT NULL,
    lease_id        TEXT NOT NULL,
    host_generation INTEGER NOT NULL,
    state           TEXT NOT NULL CHECK (state IN ('active', 'revoked', 'expired')),
    created_at      TEXT NOT NULL,
    updated_at      TEXT NOT NULL
);
CREATE UNIQUE INDEX one_active_binding ON capability_bindings(capability_id) WHERE state = 'active';

CREATE TABLE changesets (
    change_id           TEXT PRIMARY KEY,
    profile_id          TEXT NOT NULL,
    base_revision       TEXT NOT NULL,
    state               TEXT NOT NULL,
    hot_swap_level      TEXT NOT NULL,
    mode                TEXT NOT NULL,
    ops_json            TEXT NOT NULL,
    card_json           TEXT NOT NULL,
    reasons_json        TEXT NOT NULL DEFAULT '[]',
    items_json          TEXT NOT NULL DEFAULT '[]',
    target_document_json TEXT,
    target_profile_id   TEXT,
    result_kind         TEXT,
    idempotency_key     TEXT UNIQUE,
    -- The caller's own `_meta.operation_id`, so a client that lost its
    -- connection can find the change it sent (CHG-07).
    request_operation_id TEXT,
    origin_kind         TEXT NOT NULL,
    origin_json         TEXT NOT NULL,
    subject             TEXT NOT NULL,
    confirmation_json   TEXT NOT NULL,
    committed_revision  TEXT,
    failure_key         TEXT,
    created_at          TEXT NOT NULL,
    updated_at          TEXT NOT NULL,
    recovered_at        TEXT
);
CREATE INDEX changesets_by_profile ON changesets(profile_id, created_at);
CREATE INDEX changesets_in_flight ON changesets(state)
    WHERE state IN ('prepared', 'applying', 'verifying', 'rolling_back');

-- The ChangeSet state machine as data; the trigger below enforces it.
CREATE TABLE change_transitions (
    from_state TEXT NOT NULL,
    to_state   TEXT NOT NULL,
    PRIMARY KEY (from_state, to_state)
);

CREATE TABLE operations (
    operation_id    TEXT PRIMARY KEY,
    change_id       TEXT NOT NULL REFERENCES changesets(change_id),
    seq             INTEGER NOT NULL,
    participant     TEXT NOT NULL,
    step            TEXT NOT NULL,
    state           TEXT NOT NULL CHECK (state IN ('started', 'succeeded', 'failed', 'unknown')),
    request_json    TEXT NOT NULL,
    readback_json   TEXT,
    started_at      TEXT NOT NULL,
    ended_at        TEXT,
    started_mono_ns INTEGER NOT NULL,
    ended_mono_ns   INTEGER,
    UNIQUE (change_id, seq)
);

CREATE TABLE snapshots (
    snapshot_id  TEXT PRIMARY KEY,
    change_id    TEXT NOT NULL,
    scope        TEXT NOT NULL,
    data_version TEXT,
    path         TEXT,
    restorable   INTEGER NOT NULL,
    created_at   TEXT NOT NULL
);

CREATE TABLE migration_records (
    record_id    INTEGER PRIMARY KEY,
    plugin_id    TEXT NOT NULL,
    from_version TEXT NOT NULL,
    to_version   TEXT NOT NULL,
    reversible   INTEGER NOT NULL,
    result       TEXT NOT NULL,
    at           TEXT NOT NULL
);

CREATE TABLE permission_grants (
    grant_id           TEXT PRIMARY KEY,
    subject            TEXT NOT NULL,
    capability_pattern TEXT NOT NULL,
    resource           TEXT,
    granted_at         TEXT NOT NULL,
    expires_at         TEXT,
    revoked_at         TEXT,
    granted_by         TEXT NOT NULL,
    idempotency_key    TEXT UNIQUE
);

CREATE TABLE audit_log (
    audit_id        INTEGER PRIMARY KEY,
    ts              TEXT NOT NULL,
    session_id      TEXT,
    change_id       TEXT,
    operation_id    TEXT,
    subject         TEXT NOT NULL,
    action          TEXT NOT NULL,
    decision        TEXT NOT NULL,
    redacted_detail TEXT NOT NULL
);

CREATE TABLE jobs (
    job_id          TEXT PRIMARY KEY,
    kind            TEXT NOT NULL,
    state           TEXT NOT NULL CHECK (state IN ('queued', 'running', 'succeeded', 'failed', 'cancelled')),
    progress        REAL,
    result_json     TEXT,
    error_key       TEXT,
    idempotency_key TEXT UNIQUE,
    created_at      TEXT NOT NULL,
    updated_at      TEXT NOT NULL
);

-- Reserved so G2/G3 add rows, not tables. G1 writes none of them.
CREATE TABLE sessions (session_id TEXT PRIMARY KEY, created_at TEXT NOT NULL, meta_json TEXT NOT NULL);
CREATE TABLE messages (message_id TEXT PRIMARY KEY, session_id TEXT NOT NULL, seq INTEGER NOT NULL, created_at TEXT NOT NULL, body_ref TEXT NOT NULL);
CREATE TABLE tasks (task_id TEXT PRIMARY KEY, session_id TEXT, state TEXT NOT NULL, created_at TEXT NOT NULL, meta_json TEXT NOT NULL);
CREATE TABLE generated_artifacts (artifact_id TEXT PRIMARY KEY, created_at TEXT NOT NULL, meta_json TEXT NOT NULL);

-- Retention may delete revisions only while it has an open marker in this
-- transaction; anything else that tries is refused.
CREATE TABLE retention_gc (marker INTEGER PRIMARY KEY CHECK (marker = 1));

CREATE TRIGGER revisions_immutable_update BEFORE UPDATE ON revisions
BEGIN SELECT RAISE(ABORT, 'revisions are immutable'); END;

CREATE TRIGGER revisions_delete_only_by_retention BEFORE DELETE ON revisions
WHEN NOT EXISTS (SELECT 1 FROM retention_gc)
BEGIN SELECT RAISE(ABORT, 'revisions are deleted only by retention'); END;

CREATE TRIGGER plugin_instances_immutable BEFORE UPDATE ON plugin_instances
BEGIN SELECT RAISE(ABORT, 'plugin instances are immutable'); END;

CREATE TRIGGER changesets_start_as_draft BEFORE INSERT ON changesets
WHEN NEW.state <> 'draft'
BEGIN SELECT RAISE(ABORT, 'a changeset starts as draft'); END;

CREATE TRIGGER changesets_legal_transition BEFORE UPDATE OF state ON changesets
WHEN NEW.state <> OLD.state AND NOT EXISTS (
    SELECT 1 FROM change_transitions WHERE from_state = OLD.state AND to_state = NEW.state)
BEGIN SELECT RAISE(ABORT, 'illegal changeset state transition'); END;

CREATE TRIGGER changesets_no_delete BEFORE DELETE ON changesets
BEGIN SELECT RAISE(ABORT, 'changesets are history'); END;

CREATE TRIGGER audit_append_only_update BEFORE UPDATE ON audit_log
BEGIN SELECT RAISE(ABORT, 'audit log is append-only'); END;
CREATE TRIGGER audit_append_only_delete BEFORE DELETE ON audit_log
BEGIN SELECT RAISE(ABORT, 'audit log is append-only'); END;

CREATE TRIGGER grants_no_delete BEFORE DELETE ON permission_grants
BEGIN SELECT RAISE(ABORT, 'grants are revoked, never deleted'); END;
CREATE TRIGGER grants_only_revoke BEFORE UPDATE ON permission_grants
WHEN OLD.revoked_at IS NOT NULL
  OR NEW.grant_id IS NOT OLD.grant_id OR NEW.subject IS NOT OLD.subject
  OR NEW.capability_pattern IS NOT OLD.capability_pattern OR NEW.resource IS NOT OLD.resource
  OR NEW.granted_at IS NOT OLD.granted_at OR NEW.expires_at IS NOT OLD.expires_at
  OR NEW.granted_by IS NOT OLD.granted_by OR NEW.idempotency_key IS NOT OLD.idempotency_key
BEGIN SELECT RAISE(ABORT, 'a grant can only be revoked, once'); END;
"#;

fn transitions_sql() -> String {
    let mut sql = String::new();
    for from in ChangeState::ALL {
        for to in from.allowed_next() {
            sql.push_str(&format!(
                "INSERT INTO change_transitions VALUES ('{}', '{}');\n",
                from.as_str(),
                to.as_str()
            ));
        }
    }
    sql
}

pub fn configure(connection: &Connection) -> StoreResult<()> {
    connection.pragma_update(None, "journal_mode", "WAL")?;
    connection.pragma_update(None, "synchronous", "FULL")?;
    connection.pragma_update(None, "foreign_keys", "ON")?;
    connection.busy_timeout(std::time::Duration::from_millis(2_000))?;
    Ok(())
}

pub fn user_version(connection: &Connection) -> StoreResult<u32> {
    Ok(connection.pragma_query_value(None, "user_version", |row| row.get(0))?)
}

/// `quick_check` at open. A failure sends Core to rescue mode; nothing tries
/// to repair automatically, because a repair could eat the protected revision.
pub fn quick_check(connection: &Connection) -> StoreResult<()> {
    let result: String = connection.query_row("PRAGMA quick_check", [], |row| row.get(0))?;
    if result != "ok" {
        return Err(StoreError::Corrupt(result));
    }
    Ok(())
}

fn apply(transaction: &Transaction<'_>, version: u32) -> StoreResult<()> {
    match version {
        1 => {
            transaction.execute_batch(V1)?;
            transaction.execute_batch(&transitions_sql())?;
        }
        2 => transaction.execute_batch(r#"
            CREATE TABLE conversations (
                session_id TEXT PRIMARY KEY, header_json TEXT NOT NULL,
                next_seq INTEGER NOT NULL DEFAULT 0, durable_seq INTEGER NOT NULL DEFAULT 0,
                create_key TEXT NOT NULL UNIQUE, create_hash TEXT NOT NULL,
                deleted_at TEXT, writer_connection TEXT, writer_lease TEXT
            );
            CREATE TABLE agent_preferences (
                singleton INTEGER PRIMARY KEY CHECK(singleton=1),
                revision INTEGER NOT NULL, settings_json TEXT NOT NULL
            );
            CREATE TABLE agent_turns (
                turn_id TEXT PRIMARY KEY, session_id TEXT NOT NULL REFERENCES conversations(session_id),
                client_message_id TEXT NOT NULL UNIQUE, input_hash TEXT NOT NULL,
                state TEXT NOT NULL, turn_json TEXT NOT NULL, text_ref INTEGER NOT NULL,
                owner_connection TEXT, updated_at TEXT NOT NULL
            );
            CREATE UNIQUE INDEX one_running_turn ON agent_turns(session_id)
                WHERE state IN ('running','awaiting_approval','cancelling');
            CREATE TABLE agent_tool_intents (
                intent_id TEXT PRIMARY KEY, turn_id TEXT NOT NULL REFERENCES agent_turns(turn_id),
                call_id TEXT NOT NULL, capability_id TEXT NOT NULL, payload_hash TEXT NOT NULL,
                owner_connection TEXT NOT NULL, result_json TEXT, change_id TEXT,
                execution_started INTEGER NOT NULL DEFAULT 0,
                UNIQUE(turn_id,call_id)
            );
            CREATE TABLE agent_approvals (
                request_id TEXT PRIMARY KEY, approval_json TEXT NOT NULL,
                principal TEXT NOT NULL, owner_connection TEXT NOT NULL,
                expires_at_ms INTEGER NOT NULL, decided INTEGER NOT NULL DEFAULT 0,
                consumed INTEGER NOT NULL DEFAULT 0
            );
        "#)?,
        other => return Err(StoreError::Invalid(format!("no migration to {other}"))),
    }
    transaction.pragma_update(None, "user_version", version)?;
    Ok(())
}

/// Bring the schema to `CURRENT_VERSION`. Returns the version it started at.
pub fn migrate(connection: &mut Connection) -> StoreResult<u32> {
    let start = user_version(connection)?;
    if start > CURRENT_VERSION {
        return Err(StoreError::Invalid(format!(
            "database schema {start} is newer than this build ({CURRENT_VERSION})"
        )));
    }
    for version in (start + 1)..=CURRENT_VERSION {
        let transaction = connection.transaction()?;
        apply(&transaction, version)?;
        transaction.commit()?;
    }
    Ok(start)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn v1_migration_preserves_profiles_and_creates_a_readable_v1_backup() {
        let root = crate::testing::temp_root("v1-migration");
        let paths = crate::Paths::under(&root);
        paths.create().unwrap();
        let lock = crate::WriterLock::acquire(&paths.lock()).unwrap();
        let mut db = Connection::open(paths.database()).unwrap();
        configure(&db).unwrap();
        let document = ditto_protocol::profile::ProfileDocument {
            schema_version: 1,
            entries: vec![],
            slots: Default::default(),
            shortcuts: vec![],
            avatar: Default::default(),
            layout: ditto_protocol::profile::LayoutIntent {
                workspace_grid: [3, 3],
                rules: vec![],
            },
            appearance: ditto_protocol::profile::Appearance {
                theme: "legacy".into(),
                tokens: Default::default(),
                reduced_motion: false,
                reduced_transparency: false,
                low_power_style: false,
                locale: "zh-TW".into(),
            },
        };
        let tx = db.transaction().unwrap();
        apply(&tx, 1).unwrap();
        let (profile, revision) = crate::profiles::create(
            &tx,
            "legacy",
            &document,
            &ditto_protocol::profile::RevisionOrigin::Create {
                from: "default".into(),
            },
        )
        .unwrap();
        tx.commit().unwrap();
        drop(db);
        let (store, report) = crate::Store::open_writer(&paths, &lock).unwrap();
        assert_eq!(report.migrated_from, Some(1));
        let backup = Connection::open(report.backup.unwrap()).unwrap();
        assert_eq!(user_version(&backup).unwrap(), 1);
        assert_eq!(
            crate::profiles::get(&backup, &profile.profile_id)
                .unwrap()
                .head_revision,
            revision.revision_id
        );
        assert_eq!(
            crate::profiles::get(store.connection(), &profile.profile_id)
                .unwrap()
                .head_revision,
            revision.revision_id
        );
        drop(store);
        drop(backup);
        drop(lock);
        std::fs::remove_dir_all(root).unwrap();
    }
    #[test]
    fn a_failed_v2_migration_rolls_back_all_new_tables() {
        let mut db = Connection::open_in_memory().unwrap();
        let tx = db.transaction().unwrap();
        apply(&tx, 1).unwrap();
        tx.commit().unwrap();
        db.execute("CREATE TABLE agent_preferences (wrong TEXT)", [])
            .unwrap();
        assert!(migrate(&mut db).is_err());
        assert_eq!(user_version(&db).unwrap(), 1);
        let conversations: bool = db
            .query_row(
                "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE name='conversations')",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert!(!conversations);
    }
}
