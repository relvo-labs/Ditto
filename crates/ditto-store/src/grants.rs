//! Permission grants. Revoking sets `revoked_at` and keeps the row; the
//! trigger refuses deletes and any other update.

use ditto_protocol::{ids, services::Grant};
use rusqlite::{params, Connection, OptionalExtension, Row};

use crate::{
    error::{StoreError, StoreResult},
    time,
};

const COLUMNS: &str =
    "grant_id, subject, capability_pattern, resource, granted_at, expires_at, revoked_at, granted_by";

fn row(row: &Row<'_>) -> rusqlite::Result<Grant> {
    Ok(Grant {
        grant_id: row.get(0)?,
        subject: row.get(1)?,
        scope: row.get(2)?,
        resource: row.get(3)?,
        granted_at: row.get(4)?,
        expires_at: row.get(5)?,
        revoked_at: row.get(6)?,
        granted_by: row.get(7)?,
    })
}

pub struct NewGrant<'a> {
    /// A file grant's scope names the grant itself (`files:<grant_id>`), so
    /// the caller picks the id; `None` generates one.
    pub grant_id: Option<&'a str>,
    pub subject: &'a str,
    pub scope: &'a str,
    pub resource: Option<&'a str>,
    pub expires_at: Option<&'a str>,
    pub granted_by: &'a str,
    pub idempotency_key: Option<&'a str>,
}

pub fn insert(connection: &Connection, grant: &NewGrant<'_>) -> StoreResult<Grant> {
    if let Some(key) = grant.idempotency_key {
        if let Some(existing) = by_idempotency_key(connection, key)? {
            return Ok(existing);
        }
    }
    let grant_id = grant
        .grant_id
        .map_or_else(|| ids::new(ids::GRANT), String::from);
    connection.execute(
        "INSERT INTO permission_grants (grant_id, subject, capability_pattern, resource, granted_at, expires_at,
            granted_by, idempotency_key) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
        params![
            grant_id,
            grant.subject,
            grant.scope,
            grant.resource,
            time::now(),
            grant.expires_at,
            grant.granted_by,
            grant.idempotency_key
        ],
    )?;
    get(connection, &grant_id)
}

pub fn get(connection: &Connection, grant_id: &str) -> StoreResult<Grant> {
    connection
        .query_row(
            &format!("SELECT {COLUMNS} FROM permission_grants WHERE grant_id = ?1"),
            [grant_id],
            row,
        )
        .optional()?
        .ok_or_else(|| StoreError::NotFound(format!("grant {grant_id}")))
}

fn by_idempotency_key(connection: &Connection, key: &str) -> StoreResult<Option<Grant>> {
    Ok(connection
        .query_row(
            &format!("SELECT {COLUMNS} FROM permission_grants WHERE idempotency_key = ?1"),
            [key],
            row,
        )
        .optional()?)
}

pub fn revoke(connection: &Connection, grant_id: &str) -> StoreResult<Grant> {
    let grant = get(connection, grant_id)?;
    if grant.revoked_at.is_some() {
        return Ok(grant);
    }
    connection.execute(
        "UPDATE permission_grants SET revoked_at = ?2 WHERE grant_id = ?1",
        params![grant_id, time::now()],
    )?;
    get(connection, grant_id)
}

pub fn list(
    connection: &Connection,
    subject: Option<&str>,
    include_revoked: bool,
) -> StoreResult<Vec<Grant>> {
    let mut statement = connection.prepare(&format!(
        "SELECT {COLUMNS} FROM permission_grants
         WHERE (?1 IS NULL OR subject = ?1) AND (?2 OR revoked_at IS NULL) ORDER BY grant_id"
    ))?;
    let rows = statement.query_map(params![subject, include_revoked], row)?;
    Ok(rows.collect::<Result<_, _>>()?)
}

/// A grant counts when it is not revoked and not past `expires_at`.
pub fn is_effective(grant: &Grant, now_millis: i64) -> bool {
    grant.revoked_at.is_none()
        && grant
            .expires_at
            .as_deref()
            .and_then(time::parse_unix_millis)
            .is_none_or(|expires| expires > now_millis)
}

/// Effective grants of `subject` whose pattern covers `scope`. A pattern is a
/// scope, or a prefix ending in `*` (`files:*` covers every file grant).
pub fn effective(connection: &Connection, subject: &str, scope: &str) -> StoreResult<Vec<Grant>> {
    let now = time::unix_millis_now();
    Ok(list(connection, Some(subject), false)?
        .into_iter()
        .filter(|grant| is_effective(grant, now) && pattern_covers(&grant.scope, scope))
        .collect())
}

pub fn pattern_covers(pattern: &str, scope: &str) -> bool {
    match pattern.strip_suffix('*') {
        Some(prefix) => scope.starts_with(prefix),
        None => pattern == scope,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testing;

    #[test]
    fn revoked_grants_stay_and_stop_counting() {
        let mut temp = testing::open("grants");
        let grant = temp
            .store
            .write(|tx| {
                insert(
                    tx,
                    &NewGrant {
                        grant_id: None,
                        subject: "host:ent-a",
                        scope: "files:grant-x",
                        resource: Some("/home/u/todo.txt"),
                        expires_at: None,
                        granted_by: "shell",
                        idempotency_key: Some("g1"),
                    },
                )
            })
            .unwrap();
        assert_eq!(
            effective(temp.store.connection(), "host:ent-a", "files:grant-x")
                .unwrap()
                .len(),
            1
        );
        temp.store.write(|tx| revoke(tx, &grant.grant_id)).unwrap();
        assert!(
            effective(temp.store.connection(), "host:ent-a", "files:grant-x")
                .unwrap()
                .is_empty()
        );
        assert_eq!(list(temp.store.connection(), None, true).unwrap().len(), 1);
        assert!(temp
            .store
            .write(|tx| {
                tx.execute("DELETE FROM permission_grants", [])?;
                Ok(())
            })
            .is_err());
        assert!(temp
            .store
            .write(|tx| {
                tx.execute("UPDATE permission_grants SET subject = 'agent'", [])?;
                Ok(())
            })
            .is_err());
    }

    #[test]
    fn patterns_cover_exact_scopes_and_prefixes_only() {
        assert!(pattern_covers("files:*", "files:grant-1"));
        assert!(pattern_covers(
            "desktop.windows.read",
            "desktop.windows.read"
        ));
        assert!(!pattern_covers(
            "desktop.windows.read",
            "desktop.windows.control"
        ));
        assert!(!pattern_covers("files:grant-1", "files:grant-2"));
    }
}
