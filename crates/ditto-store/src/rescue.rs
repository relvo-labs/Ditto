//! The two writes rescue may make without Core (D-29 proposal): move the head
//! to the last-known-good content, and disable an entry. Both only produce a
//! revision; neither runs any participant. Core mounts the new head the next
//! time it starts and reads back what it actually got.

use ditto_protocol::profile::{ProfileDocument, RevisionOrigin, RevisionSummary};
use rusqlite::Connection;

use crate::{
    audit::{self, AuditEntry},
    error::{StoreError, StoreResult},
    profiles,
};

pub const ACTION_RESTORE: &str = "restore_last_good";
pub const ACTION_DISABLE: &str = "disable";

fn origin(offline: bool, action: &str) -> RevisionOrigin {
    if offline {
        RevisionOrigin::RescueOffline {
            action: action.into(),
        }
    } else {
        RevisionOrigin::Rescue {
            action: action.into(),
        }
    }
}

pub fn resolve_profile(connection: &Connection, profile_id: Option<&str>) -> StoreResult<String> {
    match profile_id {
        Some(id) => Ok(id.to_string()),
        None => profiles::active_profile(connection)?
            .ok_or_else(|| StoreError::NotFound("no active profile".into())),
    }
}

/// The document `restore_last_good` would make the head, if there is one.
pub fn last_good_document(
    connection: &Connection,
    profile_id: &str,
) -> StoreResult<(String, ProfileDocument)> {
    let profile = profiles::get(connection, profile_id)?;
    let good = profile
        .last_known_good
        .ok_or_else(|| StoreError::NotFound("no last-known-good revision yet".into()))?;
    let (_, document) = profiles::revision(connection, &good)?;
    Ok((good, document))
}

/// The document with every entry matching `target` (entry id or package id)
/// disabled; errors when nothing matches.
pub fn disabled_document(document: &ProfileDocument, target: &str) -> StoreResult<ProfileDocument> {
    let mut changed = document.clone();
    let mut matched = false;
    for entry in &mut changed.entries {
        if entry.entry_id == target || entry.package == target {
            matched = true;
            entry.disabled = true;
        }
    }
    if !matched {
        return Err(StoreError::NotFound(format!(
            "no entry or package {target}"
        )));
    }
    Ok(changed)
}

/// Offline restore: a new head revision whose content is the last-known-good.
pub fn restore_last_good_offline(
    connection: &Connection,
    profile_id: Option<&str>,
    subject: &str,
) -> StoreResult<RevisionSummary> {
    let profile_id = resolve_profile(connection, profile_id)?;
    let head = profiles::get(connection, &profile_id)?.head_revision;
    let (good, document) = last_good_document(connection, &profile_id)?;
    let revision = profiles::insert_revision(
        connection,
        &profile_id,
        Some(&head),
        &document,
        &origin(true, ACTION_RESTORE),
        None,
    )?;
    profiles::set_head(connection, &profile_id, &revision.revision_id)?;
    audit::append(
        connection,
        &AuditEntry {
            subject,
            action: "rescue.restore_last_good.offline",
            decision: "applied",
            redacted_detail: &format!(
                "from {head} to content of {good} as {}",
                revision.revision_id
            ),
            ..Default::default()
        },
    )?;
    Ok(revision)
}

/// Offline disable: a new head revision with the target entries disabled.
pub fn disable_offline(
    connection: &Connection,
    profile_id: Option<&str>,
    target: &str,
    subject: &str,
) -> StoreResult<RevisionSummary> {
    let profile_id = resolve_profile(connection, profile_id)?;
    let (profile, _, document) = profiles::head_document(connection, &profile_id)?;
    let changed = disabled_document(&document, target)?;
    let revision = profiles::insert_revision(
        connection,
        &profile_id,
        Some(&profile.head_revision),
        &changed,
        &origin(true, ACTION_DISABLE),
        None,
    )?;
    profiles::set_head(connection, &profile_id, &revision.revision_id)?;
    audit::append(
        connection,
        &AuditEntry {
            subject,
            action: "rescue.disable.offline",
            decision: "applied",
            redacted_detail: &format!("disabled {target} as {}", revision.revision_id),
            ..Default::default()
        },
    )?;
    Ok(revision)
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::{testing, Paths, Store, WriterLock};
    use ditto_protocol::{ids, profile::*};
    use std::collections::BTreeMap;

    /// Other tests spawn `tar`; a child between fork and exec holds a copy
    /// of every descriptor, this lock's included, so a re-acquire right after
    /// a drop can see `Locked` for that instant. Core never re-acquires (it
    /// holds the lock for its whole life), so only the test waits it out.
    fn acquire_after_release(path: &std::path::Path) -> WriterLock {
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        loop {
            match WriterLock::acquire(path) {
                Err(crate::StoreError::Locked) if std::time::Instant::now() < deadline => {
                    std::thread::sleep(std::time::Duration::from_millis(10))
                }
                other => return other.unwrap(),
            }
        }
    }

    pub fn document() -> ProfileDocument {
        ProfileDocument {
            schema_version: SCHEMA_VERSION,
            entries: vec![EntrySpec {
                entry_id: ids::new(ids::ENTRY),
                package: "ditto.svc.tasks".into(),
                version: "1.0.0".into(),
                host: HostKind::Cordis,
                config: serde_json::json!({}),
                disabled: false,
            }],
            slots: BTreeMap::new(),
            layout: LayoutIntent {
                workspace_grid: [3, 3],
                rules: vec![],
            },
            appearance: Appearance {
                theme: "soft-jelly".into(),
                tokens: BTreeMap::new(),
                reduced_motion: false,
                reduced_transparency: false,
                low_power_style: false,
                locale: "zh-TW".into(),
            },
            shortcuts: vec![],
            avatar: AvatarSettings::default(),
        }
    }

    #[test]
    fn a_second_writer_is_refused_while_the_first_holds_the_lock() {
        let temp = testing::open("lock");
        let paths = Paths::under(&temp.root);
        assert!(matches!(
            WriterLock::acquire(&paths.lock()),
            Err(StoreError::Locked)
        ));
        drop(temp);
    }

    #[test]
    fn offline_restore_and_disable_only_write_revisions() {
        let root = testing::temp_root("offline");
        let paths = Paths::under(&root);
        let good = {
            let lock = WriterLock::acquire(&paths.lock()).unwrap();
            let (mut store, _) = Store::open_writer(&paths, &lock).unwrap();
            let origin = RevisionOrigin::Create {
                from: "default".into(),
            };
            store
                .write(|tx| {
                    let (profile, first) = profiles::create(tx, "預設", &document(), &origin)?;
                    profiles::set_active_profile(tx, &profile.profile_id)?;
                    profiles::set_last_known_good(tx, &profile.profile_id, &first.revision_id)?;
                    let mut broken = document();
                    broken.appearance.theme = "broken".into();
                    let second = profiles::insert_revision(
                        tx,
                        &profile.profile_id,
                        Some(&first.revision_id),
                        &broken,
                        &origin,
                        None,
                    )?;
                    profiles::set_head(tx, &profile.profile_id, &second.revision_id)?;
                    Ok(first)
                })
                .unwrap()
        };
        // Core is gone; rescue takes the same lock and writes through the same code.
        let lock = acquire_after_release(&paths.lock());
        let (mut store, _) = Store::open_writer(&paths, &lock).unwrap();
        let restored = store
            .write(|tx| restore_last_good_offline(tx, None, "cli:rescue"))
            .unwrap();
        let (_, restored_document) =
            profiles::revision(store.connection(), &restored.revision_id).unwrap();
        let (_, good_document) = profiles::revision(store.connection(), &good.revision_id).unwrap();
        assert_eq!(restored_document.digest(), good_document.digest());
        assert!(matches!(
            restored.origin,
            RevisionOrigin::RescueOffline { .. }
        ));
        let disabled = store
            .write(|tx| disable_offline(tx, None, "ditto.svc.tasks", "cli:rescue"))
            .unwrap();
        let (_, document) = profiles::revision(store.connection(), &disabled.revision_id).unwrap();
        assert!(document.entries.iter().all(|entry| entry.disabled));
        assert!(store
            .write(|tx| disable_offline(tx, None, "ditto.missing", "cli:rescue"))
            .is_err());
        let _ = std::fs::remove_dir_all(root);
    }
}
