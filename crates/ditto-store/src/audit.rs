//! Append-only audit log. Detail is redacted by the caller before it gets
//! here; the store refuses updates and deletes by trigger.

use rusqlite::{params, Connection};

use crate::{error::StoreResult, time};

#[derive(Clone, Debug, Default)]
pub struct AuditEntry<'a> {
    pub session_id: Option<&'a str>,
    pub change_id: Option<&'a str>,
    pub operation_id: Option<&'a str>,
    pub subject: &'a str,
    pub action: &'a str,
    pub decision: &'a str,
    pub redacted_detail: &'a str,
}

pub fn append(connection: &Connection, entry: &AuditEntry<'_>) -> StoreResult<()> {
    connection.execute(
        "INSERT INTO audit_log (ts, session_id, change_id, operation_id, subject, action, decision, redacted_detail)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
        params![
            time::now(),
            entry.session_id,
            entry.change_id,
            entry.operation_id,
            entry.subject,
            entry.action,
            entry.decision,
            entry.redacted_detail
        ],
    )?;
    Ok(())
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AuditRow {
    pub ts: String,
    pub change_id: Option<String>,
    pub operation_id: Option<String>,
    pub subject: String,
    pub action: String,
    pub decision: String,
    pub redacted_detail: String,
}

pub fn recent(
    connection: &Connection,
    change_id: Option<&str>,
    limit: u32,
) -> StoreResult<Vec<AuditRow>> {
    let mut statement = connection.prepare(
        "SELECT ts, change_id, operation_id, subject, action, decision, redacted_detail FROM audit_log
         WHERE (?1 IS NULL OR change_id = ?1) ORDER BY audit_id DESC LIMIT ?2",
    )?;
    let rows = statement.query_map(params![change_id, limit], |row| {
        Ok(AuditRow {
            ts: row.get(0)?,
            change_id: row.get(1)?,
            operation_id: row.get(2)?,
            subject: row.get(3)?,
            action: row.get(4)?,
            decision: row.get(5)?,
            redacted_detail: row.get(6)?,
        })
    })?;
    Ok(rows.collect::<Result<_, _>>()?)
}
