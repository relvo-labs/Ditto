//! Profiles and their immutable revisions. A new revision is always a new row;
//! the head moves by one UPDATE in the same transaction, so a failed write
//! (full disk, I/O error) leaves the head exactly where it was.

use ditto_protocol::{
    ids,
    profile::{ProfileDocument, ProfileSummary, RevisionOrigin, RevisionSummary},
};
use rusqlite::{params, Connection, OptionalExtension, Row};

use crate::{
    error::{StoreError, StoreResult},
    time,
};

pub const ACTIVE_PROFILE_KEY: &str = "active_profile";

fn origin_kind(origin: &RevisionOrigin) -> &'static str {
    match origin {
        RevisionOrigin::Create { .. } => "create",
        RevisionOrigin::Duplicate { .. } => "duplicate",
        RevisionOrigin::Change { .. } => "change",
        RevisionOrigin::Import => "import",
        RevisionOrigin::RescueOffline { .. } => "rescue_offline",
        RevisionOrigin::Rescue { .. } => "rescue",
    }
}

fn profile_row(row: &Row<'_>, active: Option<&str>) -> rusqlite::Result<ProfileSummary> {
    let profile_id: String = row.get(0)?;
    Ok(ProfileSummary {
        active: active == Some(profile_id.as_str()),
        profile_id,
        name: row.get(1)?,
        head_revision: row.get(2)?,
        last_known_good: row.get(3)?,
        created_at: row.get(4)?,
        updated_at: row.get(5)?,
    })
}

const PROFILE_COLUMNS: &str =
    "profile_id, name, head_revision, last_known_good, created_at, updated_at";

pub fn active_profile(connection: &Connection) -> StoreResult<Option<String>> {
    Ok(connection
        .query_row(
            "SELECT value FROM core_meta WHERE key = ?1",
            [ACTIVE_PROFILE_KEY],
            |row| row.get(0),
        )
        .optional()?)
}

pub fn set_active_profile(connection: &Connection, profile_id: &str) -> StoreResult<()> {
    get(connection, profile_id)?;
    connection.execute(
        "INSERT INTO core_meta (key, value) VALUES (?1, ?2)
         ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        params![ACTIVE_PROFILE_KEY, profile_id],
    )?;
    Ok(())
}

pub fn list(connection: &Connection) -> StoreResult<Vec<ProfileSummary>> {
    let active = active_profile(connection)?;
    let mut statement = connection.prepare(&format!(
        "SELECT {PROFILE_COLUMNS} FROM profiles WHERE deleted_at IS NULL ORDER BY created_at"
    ))?;
    let rows = statement.query_map([], |row| profile_row(row, active.as_deref()))?;
    Ok(rows.collect::<Result<_, _>>()?)
}

pub fn get(connection: &Connection, profile_id: &str) -> StoreResult<ProfileSummary> {
    let active = active_profile(connection)?;
    connection
        .query_row(
            &format!("SELECT {PROFILE_COLUMNS} FROM profiles WHERE profile_id = ?1 AND deleted_at IS NULL"),
            [profile_id],
            |row| profile_row(row, active.as_deref()),
        )
        .optional()?
        .ok_or_else(|| StoreError::NotFound(format!("profile {profile_id}")))
}

pub fn find_by_name(connection: &Connection, name: &str) -> StoreResult<Option<ProfileSummary>> {
    let active = active_profile(connection)?;
    Ok(connection
        .query_row(
            &format!(
                "SELECT {PROFILE_COLUMNS} FROM profiles WHERE name = ?1 AND deleted_at IS NULL"
            ),
            [name],
            |row| profile_row(row, active.as_deref()),
        )
        .optional()?)
}

fn revision_row(row: &Row<'_>) -> rusqlite::Result<(RevisionSummary, String)> {
    let origin_json: String = row.get(4)?;
    let origin: RevisionOrigin = serde_json::from_str(&origin_json).map_err(|error| {
        rusqlite::Error::FromSqlConversionFailure(4, rusqlite::types::Type::Text, Box::new(error))
    })?;
    Ok((
        RevisionSummary {
            revision_id: row.get(0)?,
            profile_id: row.get(1)?,
            parent: row.get(2)?,
            document_sha256: row.get(3)?,
            origin,
            created_at: row.get(5)?,
            pending_confirmation: row.get::<_, Option<i64>>(6)?.unwrap_or(0) != 0,
            unstable: row.get::<_, Option<i64>>(7)?.unwrap_or(0) != 0,
            last_known_good: row.get::<_, i64>(8)? != 0,
        },
        row.get(9)?,
    ))
}

const REVISION_SELECT: &str =
    "SELECT r.revision_id, r.profile_id, r.parent, r.document_sha256, r.origin_json, r.created_at,
        f.pending_confirmation, f.unstable,
        EXISTS (SELECT 1 FROM profiles p WHERE p.last_known_good = r.revision_id),
        r.document_json
     FROM revisions r LEFT JOIN revision_flags f ON f.revision_id = r.revision_id";

pub fn revision(
    connection: &Connection,
    revision_id: &str,
) -> StoreResult<(RevisionSummary, ProfileDocument)> {
    let (summary, document) = connection
        .query_row(
            &format!("{REVISION_SELECT} WHERE r.revision_id = ?1"),
            [revision_id],
            revision_row,
        )
        .optional()?
        .ok_or_else(|| StoreError::NotFound(format!("revision {revision_id}")))?;
    let document: ProfileDocument = serde_json::from_str(&document)?;
    Ok((summary, document))
}

/// Newest first along the parent chain, starting at `revision_id`.
pub fn history(
    connection: &Connection,
    revision_id: &str,
    limit: u32,
) -> StoreResult<Vec<RevisionSummary>> {
    let mut out = Vec::new();
    let mut next = Some(revision_id.to_string());
    while let Some(current) = next {
        if out.len() as u32 >= limit {
            break;
        }
        let Some((summary, _)) = connection
            .query_row(
                &format!("{REVISION_SELECT} WHERE r.revision_id = ?1"),
                [&current],
                revision_row,
            )
            .optional()?
        else {
            break; // The rest of the chain was cleaned up by retention.
        };
        next = summary.parent.clone();
        out.push(summary);
    }
    Ok(out)
}

/// Insert an immutable revision and its entry rows. Does not move any head.
pub fn insert_revision(
    connection: &Connection,
    profile_id: &str,
    parent: Option<&str>,
    document: &ProfileDocument,
    origin: &RevisionOrigin,
    change_id: Option<&str>,
) -> StoreResult<RevisionSummary> {
    let revision_id = ids::new(ids::REVISION);
    let created_at = time::now();
    let document_json = serde_json::to_string(document)?;
    let digest = document.digest();
    connection.execute(
        "INSERT INTO revisions (revision_id, profile_id, parent, document_json, document_sha256,
                                origin_kind, origin_json, change_id, created_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
        params![
            revision_id,
            profile_id,
            parent,
            document_json,
            digest,
            origin_kind(origin),
            serde_json::to_string(origin)?,
            change_id,
            created_at
        ],
    )?;
    connection.execute(
        "INSERT INTO revision_flags (revision_id) VALUES (?1)",
        [&revision_id],
    )?;
    for entry in &document.entries {
        connection.execute(
            "INSERT INTO plugin_instances (entry_id, profile_revision, package_id, version, host_kind, config_json, disabled)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
            params![
                entry.entry_id,
                revision_id,
                entry.package,
                entry.version,
                serde_json::to_value(entry.host)?.as_str().unwrap_or_default(),
                serde_json::to_string(&entry.config)?,
                entry.disabled
            ],
        )?;
    }
    Ok(RevisionSummary {
        revision_id,
        profile_id: profile_id.into(),
        parent: parent.map(Into::into),
        document_sha256: digest,
        origin: origin.clone(),
        created_at,
        pending_confirmation: false,
        unstable: false,
        last_known_good: false,
    })
}

/// Move the head. The caller has checked the expected base inside the same
/// transaction; this refuses a head that does not belong to the profile.
pub fn set_head(connection: &Connection, profile_id: &str, revision_id: &str) -> StoreResult<()> {
    let owner: Option<String> = connection
        .query_row(
            "SELECT profile_id FROM revisions WHERE revision_id = ?1",
            [revision_id],
            |row| row.get(0),
        )
        .optional()?;
    if owner.as_deref() != Some(profile_id) {
        return Err(StoreError::Invalid(format!(
            "revision {revision_id} does not belong to {profile_id}"
        )));
    }
    let changed = connection.execute(
        "UPDATE profiles SET head_revision = ?2, updated_at = ?3 WHERE profile_id = ?1 AND deleted_at IS NULL",
        params![profile_id, revision_id, time::now()],
    )?;
    if changed != 1 {
        return Err(StoreError::NotFound(format!("profile {profile_id}")));
    }
    Ok(())
}

/// Create a profile with its first revision; both rows or neither.
pub fn create(
    connection: &Connection,
    name: &str,
    document: &ProfileDocument,
    origin: &RevisionOrigin,
) -> StoreResult<(ProfileSummary, RevisionSummary)> {
    validate_name(name)?;
    if find_by_name(connection, name)?.is_some() {
        return Err(StoreError::Conflict(format!(
            "a profile named {name} exists"
        )));
    }
    let profile_id = ids::new(ids::PROFILE);
    let now = time::now();
    // The revision references the profile and the profile the revision; the
    // foreign keys are deferred to the end of the transaction for this.
    let revision = insert_revision(connection, &profile_id, None, document, origin, None)?;
    connection.execute(
        "INSERT INTO profiles (profile_id, name, head_revision, last_known_good, created_at, updated_at)
         VALUES (?1, ?2, ?3, NULL, ?4, ?4)",
        params![profile_id, name, revision.revision_id, now],
    )?;
    Ok((get(connection, &profile_id)?, revision))
}

pub fn validate_name(name: &str) -> StoreResult<()> {
    let trimmed = name.trim();
    if trimmed.is_empty() || trimmed.chars().count() > 64 || trimmed != name {
        return Err(StoreError::Invalid(
            "a profile name is 1–64 characters with no leading or trailing space".into(),
        ));
    }
    Ok(())
}

pub fn rename(
    connection: &Connection,
    profile_id: &str,
    name: &str,
) -> StoreResult<ProfileSummary> {
    validate_name(name)?;
    if let Some(existing) = find_by_name(connection, name)? {
        if existing.profile_id != profile_id {
            return Err(StoreError::Conflict(format!(
                "a profile named {name} exists"
            )));
        }
    }
    let changed = connection.execute(
        "UPDATE profiles SET name = ?2, updated_at = ?3 WHERE profile_id = ?1 AND deleted_at IS NULL",
        params![profile_id, name, time::now()],
    )?;
    if changed != 1 {
        return Err(StoreError::NotFound(format!("profile {profile_id}")));
    }
    get(connection, profile_id)
}

/// Soft delete. The active profile cannot be deleted; its revisions stay for
/// retention to decide.
pub fn soft_delete(connection: &Connection, profile_id: &str) -> StoreResult<ProfileSummary> {
    let summary = get(connection, profile_id)?;
    if summary.active {
        return Err(StoreError::Conflict(
            "the active profile cannot be deleted".into(),
        ));
    }
    connection.execute(
        "UPDATE profiles SET deleted_at = ?2, updated_at = ?2 WHERE profile_id = ?1",
        params![profile_id, time::now()],
    )?;
    Ok(summary)
}

pub fn set_last_known_good(
    connection: &Connection,
    profile_id: &str,
    revision_id: &str,
) -> StoreResult<()> {
    connection.execute(
        "UPDATE profiles SET last_known_good = ?2 WHERE profile_id = ?1",
        params![profile_id, revision_id],
    )?;
    Ok(())
}

pub fn set_pending_confirmation(
    connection: &Connection,
    revision_id: &str,
    pending: bool,
) -> StoreResult<()> {
    connection.execute(
        "UPDATE revision_flags SET pending_confirmation = ?2 WHERE revision_id = ?1",
        params![revision_id, pending],
    )?;
    Ok(())
}

pub fn mark_unstable(connection: &Connection, revision_id: &str) -> StoreResult<()> {
    connection.execute(
        "UPDATE revision_flags SET unstable = 1 WHERE revision_id = ?1",
        [revision_id],
    )?;
    Ok(())
}

pub fn head_document(
    connection: &Connection,
    profile_id: &str,
) -> StoreResult<(ProfileSummary, RevisionSummary, ProfileDocument)> {
    let profile = get(connection, profile_id)?;
    let (revision, document) = revision(connection, &profile.head_revision)?;
    Ok((profile, revision, document))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testing;
    use ditto_protocol::profile::*;
    use std::collections::BTreeMap;

    pub fn document() -> ProfileDocument {
        ProfileDocument {
            schema_version: SCHEMA_VERSION,
            entries: vec![EntrySpec {
                entry_id: ids::new(ids::ENTRY),
                package: "ditto.dock.bottom".into(),
                version: "1.0.0".into(),
                host: HostKind::Qml,
                config: serde_json::json!({}),
                disabled: false,
                area: None,
            }],
            slots: BTreeMap::new(),
            layout: LayoutIntent {
                workspace_grid: [3, 3],
                rules: vec![],
                regions: vec![],
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
    fn revisions_are_immutable_and_heads_move_atomically() {
        let mut temp = testing::open("revisions");
        let origin = RevisionOrigin::Create {
            from: "default".into(),
        };
        let (profile, first) = temp
            .store
            .write(|tx| create(tx, "預設", &document(), &origin))
            .unwrap();
        assert_eq!(profile.head_revision, first.revision_id);
        // UPDATE and DELETE of a revision are refused by trigger.
        let refused = temp.store.write(|tx| {
            tx.execute("UPDATE revisions SET document_json = '{}'", [])?;
            Ok(())
        });
        assert!(refused.is_err());
        let refused = temp.store.write(|tx| {
            tx.execute("DELETE FROM revisions", [])?;
            Ok(())
        });
        assert!(refused.is_err());
        // A failed transaction leaves the head where it was.
        let failed: StoreResult<()> = temp.store.write(|tx| {
            let mut changed = document();
            changed.appearance.locale = "en".into();
            let second = insert_revision(
                tx,
                &profile.profile_id,
                Some(&first.revision_id),
                &changed,
                &origin,
                None,
            )?;
            set_head(tx, &profile.profile_id, &second.revision_id)?;
            Err(StoreError::StorageFull)
        });
        assert!(matches!(failed, Err(StoreError::StorageFull)));
        let after = get(temp.store.connection(), &profile.profile_id).unwrap();
        assert_eq!(after.head_revision, first.revision_id);
    }

    #[test]
    fn same_content_in_any_key_order_has_one_digest() {
        let a = document();
        let text = serde_json::to_string(&a).unwrap();
        let reordered: serde_json::Value = serde_json::from_str(&text).unwrap();
        let b: ProfileDocument = serde_json::from_value(reordered).unwrap();
        assert_eq!(a.digest(), b.digest());
    }

    #[test]
    fn the_active_profile_cannot_be_deleted_and_names_are_unique() {
        let mut temp = testing::open("names");
        let origin = RevisionOrigin::Create {
            from: "empty".into(),
        };
        let (profile, _) = temp
            .store
            .write(|tx| create(tx, "開發", &document(), &origin))
            .unwrap();
        temp.store
            .write(|tx| set_active_profile(tx, &profile.profile_id))
            .unwrap();
        assert!(matches!(
            temp.store.write(|tx| soft_delete(tx, &profile.profile_id)),
            Err(StoreError::Conflict(_))
        ));
        assert!(matches!(
            temp.store
                .write(|tx| create(tx, "開發", &document(), &origin)),
            Err(StoreError::Conflict(_))
        ));
        assert!(temp
            .store
            .write(|tx| rename(tx, &profile.profile_id, " 空白"))
            .is_err());
    }
}
