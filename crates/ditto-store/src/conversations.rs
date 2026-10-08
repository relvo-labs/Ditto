//! Core's append-only conversation log. Each bounded physical line is a whole
//! batch with a canonical hash. Files are authoritative; SQLite is its index.
//! Acknowledged appends are fsynced (stronger than Harness append's contract).
//! A torn final line is excluded, then quarantined before the next write.
use crate::{time, Paths, Store, StoreError, StoreResult};
use ditto_protocol::{agent::*, ids, jcs};
use rusqlite::{Connection, OptionalExtension};
use serde::{Deserialize, Serialize};
use std::{
    fs::{File, OpenOptions},
    io::{Read, Write},
    os::{
        fd::{AsRawFd, FromRawFd},
        unix::fs::OpenOptionsExt,
    },
};

const MAX_LOG_BYTES: u64 = 32 * 1024 * 1024;
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Header {
    session: Conversation,
    create_key: String,
    create_hash: String,
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Batch {
    batch_id: String,
    hash: String,
    events: Vec<SessionEvent>,
}

struct Dir(File);
impl Dir {
    fn root(paths: &Paths) -> StoreResult<Self> {
        let root = paths.state.join("conversations");
        std::fs::create_dir_all(&root)?;
        let file = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW)
            .open(root)?;
        use std::os::unix::fs::PermissionsExt;
        file.set_permissions(std::fs::Permissions::from_mode(0o700))?;
        Ok(Self(file))
    }
    fn file(&self, name: &str, flags: i32) -> StoreResult<File> {
        let name = std::ffi::CString::new(name)
            .map_err(|_| StoreError::Invalid("invalid file name".into()))?;
        // SAFETY: valid directory descriptor and NUL-terminated basename;
        // O_NOFOLLOW prevents callers replacing a log/header with a symlink.
        let fd = unsafe {
            libc::openat(
                self.0.as_raw_fd(),
                name.as_ptr(),
                flags | libc::O_NOFOLLOW | libc::O_CLOEXEC,
                0o600,
            )
        };
        if fd < 0 {
            return Err(std::io::Error::last_os_error().into());
        }
        Ok(unsafe { File::from_raw_fd(fd) })
    }
    fn session(&self, id: &str, create: bool) -> StoreResult<Self> {
        validate_id(id)?;
        if create {
            let c = std::ffi::CString::new(id).unwrap();
            let result = unsafe { libc::mkdirat(self.0.as_raw_fd(), c.as_ptr(), 0o700) };
            if result < 0 {
                return Err(std::io::Error::last_os_error().into());
            }
            self.0.sync_all()?;
        }
        Ok(Self(self.file(id, libc::O_RDONLY | libc::O_DIRECTORY)?))
    }
    fn unlink(&self, name: &str, directory: bool) -> StoreResult<()> {
        let c =
            std::ffi::CString::new(name).map_err(|_| StoreError::Invalid("invalid name".into()))?;
        let r = unsafe {
            libc::unlinkat(
                self.0.as_raw_fd(),
                c.as_ptr(),
                if directory { libc::AT_REMOVEDIR } else { 0 },
            )
        };
        if r < 0 && std::io::Error::last_os_error().kind() != std::io::ErrorKind::NotFound {
            return Err(std::io::Error::last_os_error().into());
        }
        self.0.sync_all()?;
        Ok(())
    }
}
fn validate_id(id: &str) -> StoreResult<()> {
    if id.len() > 80
        || !id.starts_with("ses-")
        || !id.bytes().all(|c| c.is_ascii_alphanumeric() || c == b'-')
    {
        return Err(StoreError::Invalid("invalid session id".into()));
    }
    Ok(())
}
fn validate_key(key: &str) -> StoreResult<()> {
    if key.is_empty() || key.len() > 128 || key.chars().any(char::is_control) {
        return Err(StoreError::Invalid("invalid idempotency key".into()));
    }
    Ok(())
}
fn header(dir: &Dir) -> StoreResult<Header> {
    let mut text = String::new();
    dir.file("header.json", libc::O_RDONLY)?
        .take(8193)
        .read_to_string(&mut text)?;
    if text.len() > 8192 {
        return Err(StoreError::Corrupt(
            "conversation header is oversized".into(),
        ));
    }
    let h: Header = serde_json::from_str(&text)?;
    if h.session.format_version != SESSION_FORMAT_VERSION {
        return Err(StoreError::Invalid(
            "conversation format unsupported".into(),
        ));
    }
    Ok(h)
}
fn batches(dir: &Dir) -> StoreResult<(Vec<Batch>, Vec<u8>, usize)> {
    let file = dir.file("events.jsonl", libc::O_RDONLY)?;
    if file.metadata()?.len() > MAX_LOG_BYTES {
        return Err(StoreError::Invalid(
            "conversation storage limit reached".into(),
        ));
    }
    let mut bytes = Vec::new();
    file.take(MAX_LOG_BYTES + 1).read_to_end(&mut bytes)?;
    let mut out = Vec::new();
    let mut offset = 0;
    let mut seq = 0;
    while let Some(end) = bytes[offset..].iter().position(|c| *c == b'\n') {
        let line = &bytes[offset..offset + end];
        if line.len() > MAX_EVENT_BYTES {
            return Err(StoreError::Corrupt(
                "conversation batch is oversized".into(),
            ));
        }
        let batch: Batch = serde_json::from_slice(line)
            .map_err(|_| StoreError::Corrupt("conversation batch is invalid".into()))?;
        validate_batch(&batch.events, seq)?;
        if batch.hash != jcs::digest(&serde_json::to_value(&batch.events)?) {
            return Err(StoreError::Corrupt("conversation hash mismatch".into()));
        }
        if out.iter().any(|b: &Batch| b.batch_id == batch.batch_id) {
            return Err(StoreError::Corrupt("duplicate physical batch".into()));
        }
        seq += batch.events.len() as u64;
        out.push(batch);
        offset += end + 1;
    }
    Ok((out, bytes, offset))
}
fn validate_batch(events: &[SessionEvent], next: u64) -> StoreResult<()> {
    if events.is_empty() || events.len() > MAX_BATCH_EVENTS {
        return Err(StoreError::Invalid("invalid batch length".into()));
    }
    for (i, event) in events.iter().enumerate() {
        if event.seq != next + i as u64 {
            return Err(StoreError::Conflict(
                "event sequence is not contiguous".into(),
            ));
        }
        if !event.data.is_object() {
            return Err(StoreError::Invalid("event data must be an object".into()));
        }
        if event.kind == SessionEventKind::ContextReference
            && event.data.as_object().unwrap().keys().any(|k| {
                !matches!(
                    k.as_str(),
                    "context_id" | "kind" | "label" | "hash" | "size" | "provider" | "expires_at"
                )
            })
        {
            return Err(StoreError::Invalid(
                "context events contain references only".into(),
            ));
        }
    }
    Ok(())
}
fn indexed(connection: &Connection, id: &str) -> StoreResult<Conversation> {
    validate_id(id)?;
    let text: Option<String> = connection
        .query_row(
            "SELECT header_json FROM conversations WHERE session_id=?1 AND deleted_at IS NULL",
            [id],
            |r| r.get(0),
        )
        .optional()?;
    let mut h: Conversation =
        serde_json::from_str(&text.ok_or_else(|| StoreError::NotFound("conversation".into()))?)?;
    let (next, durable): (i64, i64) = connection.query_row(
        "SELECT next_seq,durable_seq FROM conversations WHERE session_id=?1",
        [id],
        |r| Ok((r.get(0)?, r.get(1)?)),
    )?;
    h.next_seq = u64::try_from(next)
        .map_err(|_| StoreError::Corrupt("invalid conversation cursor".into()))?;
    h.durable_seq =
        u64::try_from(durable).map_err(|_| StoreError::Corrupt("invalid durable cursor".into()))?;
    Ok(h)
}
pub fn list(connection: &Connection) -> StoreResult<Vec<Conversation>> {
    let mut statement=connection.prepare("SELECT session_id FROM conversations WHERE deleted_at IS NULL ORDER BY rowid DESC LIMIT 200")?;
    let ids = statement
        .query_map([], |r| r.get::<_, String>(0))?
        .collect::<Result<Vec<_>, _>>()?;
    ids.iter().map(|id| indexed(connection, id)).collect()
}
pub fn stat(connection: &Connection, paths: &Paths, id: &str) -> StoreResult<Conversation> {
    let mut session = indexed(connection, id)?;
    let dir = Dir::root(paths)?.session(id, false)?;
    let h = header(&dir)?;
    if h.session.session_id != id {
        return Err(StoreError::Corrupt(
            "session header identity mismatch".into(),
        ));
    }
    let (batch, _, _) = batches(&dir)?;
    session.next_seq = batch.iter().map(|b| b.events.len() as u64).sum();
    // Only the SQLite watermark is an acknowledged durability promise. A
    // newer complete file prefix is recovered by the coordinator at boot.
    session.durable_seq = session.durable_seq.min(session.next_seq);
    Ok(session)
}
pub fn read(
    connection: &Connection,
    paths: &Paths,
    input: &SessionReadInput,
) -> StoreResult<SessionReadOutput> {
    if input.limit == 0 || input.limit > 200 {
        return Err(StoreError::Invalid("page limit must be 1..200".into()));
    }
    let session = stat(connection, paths, &input.session_id)?;
    let dir = Dir::root(paths)?.session(&input.session_id, false)?;
    let (batch, _, _) = batches(&dir)?;
    let events = batch
        .into_iter()
        .flat_map(|b| b.events)
        .filter(|e| e.seq >= input.offset && e.seq < session.durable_seq)
        .take(input.limit as usize)
        .collect();
    Ok(SessionReadOutput { session, events })
}
pub fn create(store: &mut Store, input: &SessionCreateInput) -> StoreResult<Conversation> {
    validate_key(&input.idempotency_key)?;
    if input.title.is_empty()
        || input.title.len() > 256
        || input.title.chars().any(char::is_control)
    {
        return Err(StoreError::Invalid("invalid title".into()));
    }
    let hash = jcs::digest(&serde_json::to_value(input)?);
    let previous: Option<(String, String)> = store
        .connection()
        .query_row(
            "SELECT session_id,create_hash FROM conversations WHERE create_key=?1",
            [&input.idempotency_key],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .optional()?;
    if let Some((id, old)) = previous {
        if old != hash {
            return Err(StoreError::Conflict(
                "create key has another payload".into(),
            ));
        }
        return indexed(store.connection(), &id);
    }
    let session = Conversation {
        session_id: format!("ses-{}", ids::ulid()),
        format_version: SESSION_FORMAT_VERSION,
        title: input.title.clone(),
        created_at: time::now(),
        next_seq: 0,
        durable_seq: 0,
    };
    let root = Dir::root(store.paths())?;
    let dir = root.session(&session.session_id, true)?;
    let h = Header {
        session: session.clone(),
        create_key: input.idempotency_key.clone(),
        create_hash: hash.clone(),
    };
    let mut file = dir.file(
        "header.partial",
        libc::O_CREAT | libc::O_EXCL | libc::O_WRONLY,
    )?;
    file.write_all(&serde_json::to_vec(&h)?)?;
    file.sync_all()?;
    dir.file(
        "events.jsonl",
        libc::O_CREAT | libc::O_EXCL | libc::O_WRONLY,
    )?
    .sync_all()?;
    let from = std::ffi::CString::new("header.partial").unwrap();
    let to = std::ffi::CString::new("header.json").unwrap();
    if unsafe {
        libc::renameat(
            dir.0.as_raw_fd(),
            from.as_ptr(),
            dir.0.as_raw_fd(),
            to.as_ptr(),
        )
    } < 0
    {
        return Err(std::io::Error::last_os_error().into());
    }
    dir.0.sync_all()?;
    root.0.sync_all()?;
    store.write(|tx| {tx.execute("INSERT INTO conversations(session_id,header_json,create_key,create_hash) VALUES(?1,?2,?3,?4)",rusqlite::params![session.session_id,serde_json::to_string(&session)?,input.idempotency_key,hash])?;Ok(())})?;
    Ok(session)
}
pub fn open(store: &mut Store, id: &str, connection: &str) -> StoreResult<SessionOpenOutput> {
    let session = stat(store.connection(), store.paths(), id)?;
    let lease = format!("writer-{}", ids::ulid());
    let lease=store.write(|tx| {
        let current:Option<(String,String)>=tx.query_row("SELECT writer_connection,writer_lease FROM conversations WHERE session_id=?1 AND writer_connection IS NOT NULL",[id],|r|Ok((r.get(0)?,r.get(1)?))).optional()?;
        if let Some((owner,existing))=current {
            if owner!=connection {return Err(StoreError::Conflict("session already has a writer".into()));}
            return Ok(existing);
        }
        tx.execute("UPDATE conversations SET writer_connection=?2,writer_lease=?3 WHERE session_id=?1",rusqlite::params![id,connection,lease])?;Ok(lease)
    })?;
    Ok(SessionOpenOutput {
        session,
        writer_lease: lease,
    })
}
fn writer(connection: &Connection, id: &str, owner: &str, lease: &str) -> StoreResult<()> {
    indexed(connection, id)?;
    let valid: bool = connection.query_row(
        "SELECT writer_connection=?2 AND writer_lease=?3 FROM conversations WHERE session_id=?1",
        rusqlite::params![id, owner, lease],
        |r| Ok(r.get::<_, Option<bool>>(0)?.unwrap_or(false)),
    )?;
    if !valid {
        return Err(StoreError::Conflict("session ownership lost".into()));
    }
    Ok(())
}
pub fn append(
    store: &mut Store,
    owner: &str,
    input: &SessionAppendInput,
) -> StoreResult<Conversation> {
    writer(
        store.connection(),
        &input.session_id,
        owner,
        &input.writer_lease,
    )?;
    validate_key(&input.batch_id)?;
    let dir = Dir::root(store.paths())?.session(&input.session_id, false)?;
    let (old, bytes, valid_bytes) = batches(&dir)?;
    let hash = jcs::digest(&serde_json::to_value(&input.events)?);
    if let Some(old) = old.iter().find(|b| b.batch_id == input.batch_id) {
        if old.hash != hash || old.events.first().map(|e| e.seq) != Some(input.expected_next_seq) {
            return Err(StoreError::Conflict("batch key has another payload".into()));
        }
        // Retry also reconciles a fsynced file whose index update failed.
        return reconcile_one(store, &input.session_id);
    }
    let next: u64 = old.iter().map(|b| b.events.len() as u64).sum();
    if input.expected_next_seq != next {
        return Err(StoreError::Conflict("stale event sequence".into()));
    }
    validate_batch(&input.events, next)?;
    let batch = Batch {
        batch_id: input.batch_id.clone(),
        hash,
        events: input.events.clone(),
    };
    let mut encoded = serde_json::to_vec(&batch)?;
    encoded.push(b'\n');
    if encoded.len() > MAX_EVENT_BYTES || valid_bytes as u64 + encoded.len() as u64 > MAX_LOG_BYTES
    {
        return Err(StoreError::Invalid(
            "conversation storage limit reached".into(),
        ));
    }
    let mut file = dir.file("events.jsonl", libc::O_RDWR)?;
    if valid_bytes != bytes.len() {
        let name = format!("torn-{}.bin", ids::ulid());
        let mut quarantine = dir.file(&name, libc::O_CREAT | libc::O_EXCL | libc::O_WRONLY)?;
        quarantine.write_all(&bytes[valid_bytes..])?;
        quarantine.sync_all()?;
        dir.0.sync_all()?;
        file.set_len(valid_bytes as u64)?;
        file.sync_all()?;
    }
    use std::io::{Seek, SeekFrom};
    file.seek(SeekFrom::End(0))?;
    file.write_all(&encoded)?;
    file.sync_all()?;
    reconcile_one(store, &input.session_id)
}
pub fn flush(
    store: &mut Store,
    owner: &str,
    input: &SessionWriteInput,
) -> StoreResult<Conversation> {
    writer(
        store.connection(),
        &input.session_id,
        owner,
        &input.writer_lease,
    )?;
    Dir::root(store.paths())?
        .session(&input.session_id, false)?
        .file("events.jsonl", libc::O_RDONLY)?
        .sync_all()?;
    reconcile_one(store, &input.session_id)
}
pub fn close(
    store: &mut Store,
    owner: &str,
    input: &SessionWriteInput,
) -> StoreResult<Conversation> {
    let current = indexed(store.connection(), &input.session_id)?;
    let lease: Option<String> = store.connection().query_row(
        "SELECT writer_lease FROM conversations WHERE session_id=?1",
        [&input.session_id],
        |r| r.get(0),
    )?;
    if lease.is_none() {
        return Ok(current);
    }
    let current = flush(store, owner, input)?;
    store.write(|tx| {
        tx.execute(
            "UPDATE conversations SET writer_connection=NULL,writer_lease=NULL WHERE session_id=?1",
            [&input.session_id],
        )?;
        Ok(())
    })?;
    Ok(current)
}
pub fn release_connection(store: &mut Store, connection: &str) -> StoreResult<()> {
    store.write(|tx| {tx.execute("UPDATE conversations SET writer_connection=NULL,writer_lease=NULL WHERE writer_connection=?1",[connection])?;Ok(())})
}
/// Core inserts a submitted message while retaining the Agent's single writer
/// lease. Both writes run on the same coordinator; no second file writer exists.
pub fn append_internal(
    store: &mut Store,
    id: &str,
    batch_id: &str,
    kind: SessionEventKind,
    data: serde_json::Value,
) -> StoreResult<u64> {
    let dir = Dir::root(store.paths())?.session(id, false)?;
    let (batches, _, _) = batches(&dir)?;
    if let Some(old) = batches.iter().find(|b| b.batch_id == batch_id) {
        if old.events.len() != 1 || old.events[0].kind != kind || old.events[0].data != data {
            return Err(StoreError::Conflict(
                "message key has another payload".into(),
            ));
        }
        reconcile_one(store, id)?;
        return Ok(old.events[0].seq);
    }
    let current:Option<(String,String)>=store.connection().query_row("SELECT writer_connection,writer_lease FROM conversations WHERE session_id=?1 AND deleted_at IS NULL AND writer_connection IS NOT NULL",[id],|r|Ok((r.get(0)?,r.get(1)?))).optional()?;
    let temporary = current.is_none();
    let (owner, lease) = match current {
        Some(pair) => pair,
        None => {
            let h = open(store, id, "core-submit")?;
            ("core-submit".into(), h.writer_lease)
        }
    };
    let next = stat(store.connection(), store.paths(), id)?.next_seq;
    let input = SessionAppendInput {
        session_id: id.into(),
        writer_lease: lease.clone(),
        batch_id: batch_id.into(),
        expected_next_seq: next,
        events: vec![SessionEvent {
            seq: next,
            kind,
            data,
        }],
    };
    let result = append(store, &owner, &input);
    if temporary {
        release_connection(store, &owner)?;
    }
    result?;
    Ok(next)
}
fn reconcile_one(store: &mut Store, id: &str) -> StoreResult<Conversation> {
    let mut session = stat(store.connection(), store.paths(), id)?;
    session.durable_seq = session.next_seq;
    let seq = i64::try_from(session.next_seq)
        .map_err(|_| StoreError::Invalid("conversation cursor overflow".into()))?;
    store.write(|tx| {tx.execute("UPDATE conversations SET next_seq=?2,durable_seq=?2 WHERE session_id=?1 AND deleted_at IS NULL",rusqlite::params![id,seq])?;Ok(())})?;
    Ok(session)
}
pub fn recover(store: &mut Store) -> StoreResult<()> {
    store.write(|tx| {
        tx.execute(
            "UPDATE conversations SET writer_connection=NULL,writer_lease=NULL",
            [],
        )?;
        Ok(())
    })?;
    // Recover materialized creates whose database acknowledgement was lost.
    let root = store.paths().state.join("conversations");
    if root.exists() {
        for entry in std::fs::read_dir(&root)? {
            let entry = entry?;
            let Some(id) = entry.file_name().to_str().map(String::from) else {
                continue;
            };
            if validate_id(&id).is_err() {
                continue;
            }
            let deleted:bool=store.connection().query_row("SELECT EXISTS(SELECT 1 FROM conversations WHERE session_id=?1 AND deleted_at IS NOT NULL)",[&id],|r|r.get(0))?;
            if deleted {
                purge_files(store.paths(), &id)?;
                continue;
            }
            let dir = Dir::root(store.paths())?.session(&id, false)?;
            if !entry.path().join("header.json").exists() {
                // A create that crashed before its header was renamed into
                // place never answered: nothing refers to it. Remove it,
                // unless the index knows the id (then it is real damage).
                let known: bool = store.connection().query_row(
                    "SELECT EXISTS(SELECT 1 FROM conversations WHERE session_id=?1)",
                    [&id],
                    |r| r.get(0),
                )?;
                if !known {
                    purge_files(store.paths(), &id)?;
                }
                continue;
            }
            let h = header(&dir)?;
            if h.session.session_id != id {
                return Err(StoreError::Corrupt("session identity mismatch".into()));
            }
            store.write(|tx| {tx.execute("INSERT OR IGNORE INTO conversations(session_id,header_json,create_key,create_hash) VALUES(?1,?2,?3,?4)",rusqlite::params![id,serde_json::to_string(&h.session)?,h.create_key,h.create_hash])?;Ok(())})?;
        }
    }
    let ids = {
        let mut q = store
            .connection()
            .prepare("SELECT session_id FROM conversations WHERE deleted_at IS NULL")?;
        let ids = q
            .query_map([], |r| r.get::<_, String>(0))?
            .collect::<Result<Vec<_>, _>>()?;
        ids
    };
    for id in ids {
        let dir = Dir::root(store.paths())?.session(&id, false)?;
        dir.file("events.jsonl", libc::O_RDWR)?.sync_all()?;
        reconcile_one(store, &id)?;
    }
    Ok(())
}
pub fn delete(store: &mut Store, id: &str) -> StoreResult<SessionDeleteOutput> {
    validate_id(id)?;
    let active:bool=store.connection().query_row("SELECT EXISTS(SELECT 1 FROM agent_turns WHERE session_id=?1 AND state IN ('queued','running','awaiting_approval','cancelling'))",[id],|r|r.get(0))?;
    if active {
        return Err(StoreError::Conflict(
            "stop active tasks before deleting conversation".into(),
        ));
    }
    store.write(|tx| {let n=tx.execute("UPDATE conversations SET deleted_at=COALESCE(deleted_at,?2),writer_connection=NULL,writer_lease=NULL WHERE session_id=?1",rusqlite::params![id,time::now()])?;
        if n==0 {return Err(StoreError::NotFound("conversation".into()));}
        tx.execute("DELETE FROM agent_approvals WHERE json_extract(approval_json,'$.request.session_id')=?1",[id])?;
        // Keep the causal ids/change references, never the deleted tool content.
        tx.execute("UPDATE agent_tool_intents SET result_json=NULL WHERE turn_id IN (SELECT turn_id FROM agent_turns WHERE session_id=?1)",[id])?;
        Ok(())
    })?;
    purge_files(store.paths(), id)?;
    Ok(SessionDeleteOutput {
        deleted: true,
        configuration_preserved: true,
    })
}

fn purge_files(paths: &Paths, id: &str) -> StoreResult<()> {
    let root = Dir::root(paths)?;
    let path = paths.state.join("conversations").join(id);
    if path.exists() {
        let dir = root.session(id, false)?;
        for file in std::fs::read_dir(&path)? {
            let file = file?;
            let name = file.file_name();
            let name = name
                .to_str()
                .ok_or_else(|| StoreError::Corrupt("invalid conversation file name".into()))?;
            dir.unlink(name, false)?;
        }
        root.unlink(id, true)?;
    }
    root.0.sync_all()?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    fn setup() -> (crate::testing::TempStore, SessionOpenOutput) {
        let mut t = crate::testing::open("conversation");
        let s = create(
            &mut t.store,
            &SessionCreateInput {
                title: "中文對話".into(),
                idempotency_key: "create".into(),
            },
        )
        .unwrap();
        let handle = open(&mut t.store, &s.session_id, "conn-1").unwrap();
        (t, handle)
    }
    fn batch(h: &SessionOpenOutput) -> SessionAppendInput {
        SessionAppendInput {
            session_id: h.session.session_id.clone(),
            writer_lease: h.writer_lease.clone(),
            batch_id: "batch-1".into(),
            expected_next_seq: 0,
            events: vec![SessionEvent {
                seq: 0,
                kind: SessionEventKind::UserMessage,
                data: serde_json::json!({"text":"移動工作列"}),
            }],
        }
    }
    #[test]
    fn writer_fencing_durable_prefix_idempotency_and_delete() {
        let (mut t, h) = setup();
        let b = batch(&h);
        assert!(open(&mut t.store, &b.session_id, "conn-2").is_err());
        assert!(append(&mut t.store, "conn-2", &b).is_err());
        assert_eq!(append(&mut t.store, "conn-1", &b).unwrap().durable_seq, 1);
        assert_eq!(append(&mut t.store, "conn-1", &b).unwrap().durable_seq, 1);
        let mut wrong = b.clone();
        wrong.events[0].data = serde_json::json!({"text":"different"});
        assert!(append(&mut t.store, "conn-1", &wrong).is_err());
        release_connection(&mut t.store, "conn-1").unwrap();
        assert!(append(&mut t.store, "conn-1", &b).is_err());
        assert_eq!(
            read(
                t.store.connection(),
                t.store.paths(),
                &SessionReadInput {
                    session_id: b.session_id.clone(),
                    offset: 0,
                    limit: 50
                }
            )
            .unwrap()
            .events
            .len(),
            1
        );
        delete(&mut t.store, &b.session_id).unwrap();
        recover(&mut t.store).unwrap();
        assert!(list(t.store.connection()).unwrap().is_empty());
    }
    #[test]
    fn a_torn_tail_is_excluded_and_quarantined_but_middle_corruption_refuses() {
        let (mut t, h) = setup();
        let mut b = batch(&h);
        append(&mut t.store, "conn-1", &b).unwrap();
        let path = t
            .store
            .paths()
            .state
            .join("conversations")
            .join(&b.session_id)
            .join("events.jsonl");
        OpenOptions::new()
            .append(true)
            .open(&path)
            .unwrap()
            .write_all(b"{\"torn\"")
            .unwrap();
        assert_eq!(
            stat(t.store.connection(), t.store.paths(), &b.session_id)
                .unwrap()
                .next_seq,
            1
        );
        b.batch_id = "batch-2".into();
        b.expected_next_seq = 1;
        b.events[0].seq = 1;
        assert_eq!(append(&mut t.store, "conn-1", &b).unwrap().durable_seq, 2);
        std::fs::write(path, b"{}\n").unwrap();
        assert!(stat(t.store.connection(), t.store.paths(), &b.session_id).is_err());
    }
    #[test]
    fn path_traversal_symlinks_and_raw_context_are_refused() {
        let (mut t, h) = setup();
        assert!(stat(t.store.connection(), t.store.paths(), "ses-../escape").is_err());
        let mut b = batch(&h);
        b.events[0].kind = SessionEventKind::ContextReference;
        b.events[0].data = serde_json::json!({"text":"private"});
        assert!(append(&mut t.store, "conn-1", &b).is_err());
        let log = t
            .store
            .paths()
            .state
            .join("conversations")
            .join(&b.session_id)
            .join("events.jsonl");
        std::fs::remove_file(&log).unwrap();
        std::os::unix::fs::symlink("/etc/passwd", log).unwrap();
        assert!(stat(t.store.connection(), t.store.paths(), &b.session_id).is_err());
    }

    fn read_all(t: &crate::testing::TempStore, id: &str) -> Vec<SessionEvent> {
        read(
            t.store.connection(),
            t.store.paths(),
            &SessionReadInput {
                session_id: id.into(),
                offset: 0,
                limit: 200,
            },
        )
        .unwrap()
        .events
    }

    #[test]
    fn skipped_or_out_of_order_sequences_are_refused() {
        let (mut t, h) = setup();
        let mut b = batch(&h);
        b.expected_next_seq = 5;
        b.events[0].seq = 5;
        assert!(append(&mut t.store, "conn-1", &b).is_err());
        let mut gap = batch(&h);
        gap.events.push(SessionEvent {
            seq: 2,
            kind: SessionEventKind::AssistantMessage,
            data: serde_json::json!({"text":"skipped one"}),
        });
        assert!(append(&mut t.store, "conn-1", &gap).is_err());
        assert!(read_all(&t, &h.session.session_id).is_empty());
    }

    #[test]
    fn an_unknown_event_inside_a_committed_batch_refuses_reading() {
        let (mut t, h) = setup();
        append(&mut t.store, "conn-1", &batch(&h)).unwrap();
        let path = t
            .store
            .paths()
            .state
            .join("conversations")
            .join(&h.session.session_id)
            .join("events.jsonl");
        let text = std::fs::read_to_string(&path).unwrap();
        std::fs::write(&path, text.replace("user/message", "tool/exec")).unwrap();
        assert!(stat(t.store.connection(), t.store.paths(), &h.session.session_id).is_err());
    }

    #[test]
    fn a_create_that_crashed_before_its_rename_is_cleaned_up() {
        let mut t = crate::testing::open("conversation-orphan");
        let orphan = t
            .store
            .paths()
            .state
            .join("conversations")
            .join("ses-01ORPHAN0000000000000000000");
        std::fs::create_dir_all(&orphan).unwrap();
        std::fs::write(orphan.join("header.partial"), b"{}").unwrap();
        recover(&mut t.store).unwrap();
        assert!(!orphan.exists());
        assert!(list(t.store.connection()).unwrap().is_empty());
    }

    #[test]
    fn an_index_row_lost_after_the_rename_is_restored_from_the_header() {
        let (mut t, h) = setup();
        append(&mut t.store, "conn-1", &batch(&h)).unwrap();
        let id = h.session.session_id.clone();
        t.store
            .write(|tx| {
                tx.execute("DELETE FROM conversations WHERE session_id=?1", [&id])?;
                Ok(())
            })
            .unwrap();
        recover(&mut t.store).unwrap();
        let back = stat(t.store.connection(), t.store.paths(), &id).unwrap();
        assert_eq!(back.next_seq, 1);
        assert_eq!(read_all(&t, &id).len(), 1);
    }

    #[test]
    fn the_event_file_wins_when_the_index_disagrees() {
        let (mut t, h) = setup();
        append(&mut t.store, "conn-1", &batch(&h)).unwrap();
        let id = h.session.session_id.clone();
        for wrong in [0i64, 99] {
            t.store
                .write(|tx| {
                    tx.execute(
                        "UPDATE conversations SET next_seq=?2, durable_seq=?2 WHERE session_id=?1",
                        rusqlite::params![id, wrong],
                    )?;
                    Ok(())
                })
                .unwrap();
            // Never claims events the file does not hold, nor loses those it does.
            assert_eq!(
                stat(t.store.connection(), t.store.paths(), &id)
                    .unwrap()
                    .next_seq,
                1
            );
            recover(&mut t.store).unwrap();
            assert_eq!(
                stat(t.store.connection(), t.store.paths(), &id)
                    .unwrap()
                    .durable_seq,
                1
            );
        }
    }

    /// The size limit is per process, so the limited part runs in a child
    /// copy of this test binary: tests running beside it are not touched.
    #[test]
    fn a_full_disk_fails_the_append_and_keeps_the_log_readable() {
        if std::env::var_os("DITTO_DISK_FULL_CHILD").is_some() {
            return disk_full_child();
        }
        let output = std::process::Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "conversations::tests::a_full_disk_fails_the_append_and_keeps_the_log_readable",
                "--nocapture",
                "--test-threads=1",
            ])
            .env("DITTO_DISK_FULL_CHILD", "1")
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "{}{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
    }

    fn disk_full_child() {
        let (mut t, h) = setup();
        append(&mut t.store, "conn-1", &batch(&h)).unwrap();
        let path = t
            .store
            .paths()
            .state
            .join("conversations")
            .join(&h.session.session_id)
            .join("events.jsonl");
        let size = std::fs::metadata(&path).unwrap().len();
        let mut big = batch(&h);
        big.batch_id = "big".into();
        big.expected_next_seq = 1;
        big.events[0].seq = 1;
        big.events[0].data = serde_json::json!({"text": "滿".repeat(4000)});
        // No file may grow past this size: like a full disk for the event log
        // (EFBIG instead of SIGXFSZ, which is ignored here).
        let mut old = libc::rlimit {
            rlim_cur: 0,
            rlim_max: 0,
        };
        unsafe {
            libc::signal(libc::SIGXFSZ, libc::SIG_IGN);
            libc::getrlimit(libc::RLIMIT_FSIZE, &mut old);
            let limit = libc::rlimit {
                rlim_cur: size + 200,
                rlim_max: old.rlim_max,
            };
            libc::setrlimit(libc::RLIMIT_FSIZE, &limit);
        }
        let result = append(&mut t.store, "conn-1", &big);
        unsafe { libc::setrlimit(libc::RLIMIT_FSIZE, &old) };
        assert!(
            result.is_err(),
            "the append must fail when the file cannot grow"
        );
        // What is readable is a valid prefix.
        let events = read_all(&t, &h.session.session_id);
        assert!(!events.is_empty() && events.iter().enumerate().all(|(i, e)| e.seq == i as u64));
        // And the log takes appends again once there is room.
        let next = stat(t.store.connection(), t.store.paths(), &h.session.session_id)
            .unwrap()
            .next_seq;
        let mut again = batch(&h);
        again.batch_id = "after".into();
        again.expected_next_seq = next;
        again.events[0].seq = next;
        append(&mut t.store, "conn-1", &again).unwrap();
    }

    #[test]
    fn a_delete_interrupted_after_its_tombstone_finishes_at_recovery() {
        let (mut t, h) = setup();
        append(&mut t.store, "conn-1", &batch(&h)).unwrap();
        let id = h.session.session_id.clone();
        t.store
            .write(|tx| {
                tx.execute(
                    "UPDATE conversations SET deleted_at='now' WHERE session_id=?1",
                    [&id],
                )?;
                Ok(())
            })
            .unwrap();
        let dir = t.store.paths().state.join("conversations").join(&id);
        assert!(dir.exists());
        recover(&mut t.store).unwrap();
        assert!(!dir.exists());
        assert!(list(t.store.connection()).unwrap().is_empty());
    }
}
