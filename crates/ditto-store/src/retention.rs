//! Revision retention (CFG-07). Never removed: any profile's head and
//! last-known-good, the 20 most recent revisions on each of their parent
//! chains, revisions an unfinished or pending-confirmation change refers to.
//! Packages are protected by counting references from what remains.

use std::collections::HashSet;

use rusqlite::Connection;

use crate::{error::StoreResult, profiles};

pub const KEEP_PER_CHAIN: u32 = 20;
pub const MAX_DELETES_PER_RUN: usize = 50;

pub fn protected(connection: &Connection) -> StoreResult<HashSet<String>> {
    let mut keep = HashSet::new();
    let mut roots = Vec::new();
    {
        let mut statement =
            connection.prepare("SELECT head_revision, last_known_good FROM profiles")?;
        let rows = statement.query_map([], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, Option<String>>(1)?))
        })?;
        for row in rows {
            let (head, good) = row?;
            roots.push(head);
            roots.extend(good);
        }
    }
    for root in roots {
        for revision in profiles::history(connection, &root, KEEP_PER_CHAIN)? {
            keep.insert(revision.revision_id);
        }
    }
    let mut statement = connection.prepare(
        "SELECT base_revision FROM changesets WHERE state NOT IN ('rejected', 'aborted', 'committed', 'rolled_back', 'partially_applied', 'unknown')
         UNION SELECT committed_revision FROM changesets WHERE committed_revision IS NOT NULL
             AND confirmation_json LIKE '%\"pending\"%'
         UNION SELECT revision_id FROM revision_flags WHERE pending_confirmation = 1",
    )?;
    for row in statement.query_map([], |row| row.get::<_, Option<String>>(0))? {
        if let Some(revision) = row? {
            keep.insert(revision);
        }
    }
    Ok(keep)
}

/// One bounded pass; returns the deleted revision ids. Run it in a write
/// transaction while the coordinator is idle.
pub fn collect(connection: &Connection) -> StoreResult<Vec<String>> {
    let keep = protected(connection)?;
    let mut statement =
        connection.prepare("SELECT revision_id FROM revisions ORDER BY created_at")?;
    let candidates: Vec<String> = statement
        .query_map([], |row| row.get(0))?
        .collect::<Result<Vec<String>, _>>()?
        .into_iter()
        .filter(|revision| !keep.contains(revision))
        .take(MAX_DELETES_PER_RUN)
        .collect();
    if candidates.is_empty() {
        return Ok(candidates);
    }
    connection.execute("INSERT INTO retention_gc (marker) VALUES (1)", [])?;
    for revision in &candidates {
        connection.execute("DELETE FROM revisions WHERE revision_id = ?1", [revision])?;
    }
    connection.execute("DELETE FROM retention_gc", [])?;
    Ok(candidates)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{profiles::*, testing};
    use ditto_protocol::profile::RevisionOrigin;

    #[test]
    fn keeps_heads_last_good_and_twenty_per_chain() {
        let mut temp = testing::open("retention");
        let origin = RevisionOrigin::Create {
            from: "default".into(),
        };
        let document = crate::rescue::tests::document();
        let (profile, first) = temp
            .store
            .write(|tx| create(tx, "預設", &document, &origin))
            .unwrap();
        temp.store
            .write(|tx| set_last_known_good(tx, &profile.profile_id, &first.revision_id))
            .unwrap();
        let mut parent = first.revision_id.clone();
        for index in 0..40 {
            let mut changed = document.clone();
            changed
                .appearance
                .tokens
                .insert("n".into(), index.to_string());
            parent = temp
                .store
                .write(|tx| {
                    let revision = insert_revision(
                        tx,
                        &profile.profile_id,
                        Some(&parent),
                        &changed,
                        &origin,
                        None,
                    )?;
                    set_head(tx, &profile.profile_id, &revision.revision_id)?;
                    Ok(revision.revision_id)
                })
                .unwrap();
        }
        let deleted = temp.store.write(|tx| collect(tx)).unwrap();
        // 41 revisions: 20 on the head chain and the last-known-good stay.
        assert_eq!(deleted.len(), 20);
        assert!(!deleted.contains(&first.revision_id));
        assert!(!deleted.contains(&parent));
        assert!(revision(temp.store.connection(), &first.revision_id).is_ok());
        assert_eq!(
            history(temp.store.connection(), &parent, 100)
                .unwrap()
                .len(),
            20
        );
    }
}
