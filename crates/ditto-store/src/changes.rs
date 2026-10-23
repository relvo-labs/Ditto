//! ChangeSet records and their operations. Every state transition is written
//! before the side effect it announces; the trigger in the schema refuses any
//! transition the state machine does not allow.

use ditto_protocol::{
    change::{
        ChangeCard, ChangeMode, ChangeOp, ChangeOrigin, ChangeRecord, ChangeState, Confirmation,
        HotSwapLevel, OperationSummary, OutcomeItem, PreflightReason, SavedOnly, SavedOnlyReason,
    },
    ids,
    profile::ProfileDocument,
};
use rusqlite::{params, Connection, OptionalExtension, Row};

use crate::{
    error::{StoreError, StoreResult},
    time,
};

/// What the coordinator keeps beside the public record.
#[derive(Clone, Debug, PartialEq)]
pub struct StoredChange {
    pub record: ChangeRecord,
    pub mode: ChangeMode,
    pub subject: String,
    /// The document the change commits, computed at validation; recovery
    /// compares readbacks against it.
    pub target_document: Option<ProfileDocument>,
    /// For `switch_profile`: the profile that becomes active.
    pub target_profile: Option<String>,
}

pub struct NewChange<'a> {
    pub profile_id: &'a str,
    pub base_revision: &'a str,
    pub ops: &'a [ChangeOp],
    pub mode: ChangeMode,
    pub origin: &'a ChangeOrigin,
    pub subject: &'a str,
    pub idempotency_key: Option<&'a str>,
    pub request_operation_id: Option<&'a str>,
    pub card: &'a ChangeCard,
    pub hot_swap_level: HotSwapLevel,
}

fn json<T: serde::Serialize>(value: &T) -> StoreResult<String> {
    Ok(serde_json::to_string(value)?)
}

fn parse<T: serde::de::DeserializeOwned>(index: usize, text: &str) -> rusqlite::Result<T> {
    serde_json::from_str(text).map_err(|error| {
        rusqlite::Error::FromSqlConversionFailure(
            index,
            rusqlite::types::Type::Text,
            Box::new(error),
        )
    })
}

const COLUMNS: &str = "change_id, profile_id, base_revision, state, hot_swap_level, mode, ops_json, card_json,
    reasons_json, items_json, target_document_json, target_profile_id, idempotency_key, origin_json, subject,
    confirmation_json, committed_revision, failure_key, created_at, updated_at, recovered_at, saved_only,
    (SELECT name FROM profiles WHERE profiles.profile_id = changesets.profile_id)";

fn row(row: &Row<'_>) -> rusqlite::Result<StoredChange> {
    let state_text: String = row.get(3)?;
    let state = ChangeState::parse(&state_text).ok_or_else(|| {
        rusqlite::Error::FromSqlConversionFailure(
            3,
            rusqlite::types::Type::Text,
            format!("unknown state {state_text}").into(),
        )
    })?;
    let level_text: String = row.get(4)?;
    let hot_swap_level = HotSwapLevel::parse(&level_text).unwrap_or(HotSwapLevel::SessionRestart);
    let mode_text: String = row.get(5)?;
    let target: Option<String> = row.get(10)?;
    let items: Vec<ditto_protocol::change::OutcomeItem> = parse(9, &row.get::<_, String>(9)?)?;
    let saved_only = match row.get::<_, Option<String>>(21)? {
        None => None,
        Some(text) => Some(SavedOnly {
            reason: SavedOnlyReason::parse(&text).ok_or_else(|| {
                rusqlite::Error::FromSqlConversionFailure(
                    21,
                    rusqlite::types::Type::Text,
                    format!("unknown saved_only {text}").into(),
                )
            })?,
            profile_name: row.get::<_, Option<String>>(22)?.unwrap_or_default(),
        }),
    };
    let record = ChangeRecord {
        change_id: row.get(0)?,
        profile_id: row.get(1)?,
        base_revision: row.get(2)?,
        committed_revision: row.get(16)?,
        state,
        result: ditto_protocol::change::result_of(state, &items),
        hot_swap_level,
        origin: parse(13, &row.get::<_, String>(13)?)?,
        idempotency_key: row.get(12)?,
        ops: parse(6, &row.get::<_, String>(6)?)?,
        card: parse(7, &row.get::<_, String>(7)?)?,
        reasons: parse(8, &row.get::<_, String>(8)?)?,
        items,
        confirmation: parse(15, &row.get::<_, String>(15)?)?,
        operations: Vec::new(),
        recovered_at: row.get(20)?,
        failure_key: row.get(17)?,
        saved_only,
        created_at: row.get(18)?,
        updated_at: row.get(19)?,
    };
    Ok(StoredChange {
        record,
        mode: if mode_text == "preview" {
            ChangeMode::Preview
        } else {
            ChangeMode::Apply
        },
        subject: row.get(14)?,
        target_document: target.map(|text| parse(10, &text)).transpose()?,
        target_profile: row.get(11)?,
    })
}

pub fn insert(connection: &Connection, change: &NewChange<'_>) -> StoreResult<StoredChange> {
    let change_id = ids::new(ids::CHANGE);
    let now = time::now();
    connection.execute(
        "INSERT INTO changesets (change_id, profile_id, base_revision, state, hot_swap_level, mode, ops_json,
                card_json, idempotency_key, origin_kind, origin_json, subject, confirmation_json, created_at, updated_at,
                request_operation_id)
             VALUES (?1, ?2, ?3, 'draft', ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?13, ?14)",
        params![
            change_id,
            change.profile_id,
            change.base_revision,
            change.hot_swap_level.as_str(),
            if change.mode == ChangeMode::Preview { "preview" } else { "apply" },
            json(&change.ops)?,
            json(change.card)?,
            change.idempotency_key,
            serde_json::to_value(change.origin)?["kind"].as_str().unwrap_or("unknown"),
            json(change.origin)?,
            change.subject,
            json(&Confirmation::NotRequired)?,
            now,
            change.request_operation_id
        ],
    )?;
    get(connection, &change_id)
}

pub fn get(connection: &Connection, change_id: &str) -> StoreResult<StoredChange> {
    let mut stored = connection
        .query_row(
            &format!("SELECT {COLUMNS} FROM changesets WHERE change_id = ?1"),
            [change_id],
            row,
        )
        .optional()?
        .ok_or_else(|| StoreError::NotFound(format!("change {change_id}")))?;
    stored.record.operations = operations(connection, change_id)?;
    Ok(stored)
}

pub fn by_idempotency_key(connection: &Connection, key: &str) -> StoreResult<Option<StoredChange>> {
    let id: Option<String> = connection
        .query_row(
            "SELECT change_id FROM changesets WHERE idempotency_key = ?1",
            [key],
            |row| row.get(0),
        )
        .optional()?;
    id.map(|id| get(connection, &id)).transpose()
}

pub fn by_operation(
    connection: &Connection,
    operation_id: &str,
) -> StoreResult<Option<StoredChange>> {
    let id: Option<String> = connection
        .query_row(
            "SELECT change_id FROM operations WHERE operation_id = ?1
             UNION SELECT change_id FROM changesets WHERE request_operation_id = ?1 LIMIT 1",
            [operation_id],
            |row| row.get(0),
        )
        .optional()?;
    id.map(|id| get(connection, &id)).transpose()
}

pub fn list(
    connection: &Connection,
    profile_id: Option<&str>,
    before: Option<&str>,
    limit: u32,
) -> StoreResult<Vec<StoredChange>> {
    let mut statement = connection.prepare(&format!(
        "SELECT {COLUMNS} FROM changesets
         WHERE (?1 IS NULL OR profile_id = ?1) AND (?2 IS NULL OR change_id < ?2)
         ORDER BY change_id DESC LIMIT ?3"
    ))?;
    let rows = statement.query_map(params![profile_id, before, limit], row)?;
    Ok(rows.collect::<Result<_, _>>()?)
}

/// Changes a crash may have left between states.
pub fn in_flight(connection: &Connection) -> StoreResult<Vec<StoredChange>> {
    let mut statement = connection.prepare(&format!(
        "SELECT {COLUMNS} FROM changesets
         WHERE state IN ('draft', 'validated', 'prepared', 'applying', 'verifying', 'rolling_back')
         ORDER BY change_id"
    ))?;
    let rows = statement.query_map([], row)?;
    let mut changes: Vec<StoredChange> = rows.collect::<Result<_, _>>()?;
    for change in &mut changes {
        change.record.operations = operations(connection, &change.record.change_id)?;
    }
    Ok(changes)
}

/// The latest committed change of a profile, for the undo policy.
pub fn latest_committed(
    connection: &Connection,
    profile_id: &str,
) -> StoreResult<Option<StoredChange>> {
    let id: Option<String> = connection
        .query_row(
            "SELECT change_id FROM changesets WHERE profile_id = ?1 AND state = 'committed'
             ORDER BY change_id DESC LIMIT 1",
            [profile_id],
            |row| row.get(0),
        )
        .optional()?;
    id.map(|id| get(connection, &id)).transpose()
}

/// Committed changes of a profile made after `change_id`.
pub fn committed_after(
    connection: &Connection,
    profile_id: &str,
    change_id: &str,
) -> StoreResult<Vec<StoredChange>> {
    let mut statement = connection.prepare(&format!(
        "SELECT {COLUMNS} FROM changesets WHERE profile_id = ?1 AND state = 'committed' AND change_id > ?2
         ORDER BY change_id"
    ))?;
    let rows = statement.query_map(params![profile_id, change_id], row)?;
    Ok(rows.collect::<Result<_, _>>()?)
}

/// Record the result class of a committed change in the `result_kind`
/// column too, in the same transaction as the commit, so the column never
/// says `succeeded` for something that has not taken effect (every item
/// scheduled) or did not fully take effect (an item not restored).
pub fn settle_committed_result(connection: &Connection, change_id: &str) -> StoreResult<()> {
    use ditto_protocol::change::ResultKind;
    let stored = get(connection, change_id)?;
    let kind = match stored.record.result {
        Some(ResultKind::Scheduled) => "scheduled",
        Some(ResultKind::Partial) => "partial",
        _ => return Ok(()),
    };
    connection.execute(
        "UPDATE changesets SET result_kind = ?2 WHERE change_id = ?1",
        params![change_id, kind],
    )?;
    Ok(())
}

/// Move to `state`. The trigger refuses illegal transitions; this also
/// refuses a transition from a state other than the one the caller saw.
pub fn transition(
    connection: &Connection,
    change_id: &str,
    from: ChangeState,
    to: ChangeState,
) -> StoreResult<()> {
    let changed = connection.execute(
        "UPDATE changesets SET state = ?3, result_kind = ?4, updated_at = ?5
         WHERE change_id = ?1 AND state = ?2",
        params![
            change_id,
            from.as_str(),
            to.as_str(),
            to.result()
                .and_then(|result| serde_json::to_value(result).ok())
                .and_then(|value| value.as_str().map(String::from)),
            time::now()
        ],
    )?;
    if changed != 1 {
        return Err(StoreError::Conflict(format!(
            "change {change_id} is not in state {}",
            from.as_str()
        )));
    }
    Ok(())
}

pub fn set_validation(
    connection: &Connection,
    change_id: &str,
    ops: &[ChangeOp],
    card: &ChangeCard,
    hot_swap_level: HotSwapLevel,
    target_document: Option<&ProfileDocument>,
    target_profile: Option<&str>,
) -> StoreResult<()> {
    connection.execute(
        "UPDATE changesets SET ops_json = ?2, card_json = ?3, hot_swap_level = ?4, target_document_json = ?5,
            target_profile_id = ?6, updated_at = ?7 WHERE change_id = ?1",
        params![
            change_id,
            json(&ops)?,
            json(card)?,
            hot_swap_level.as_str(),
            target_document.map(json).transpose()?,
            target_profile,
            time::now()
        ],
    )?;
    Ok(())
}

pub fn set_reasons(
    connection: &Connection,
    change_id: &str,
    reasons: &[PreflightReason],
) -> StoreResult<()> {
    connection.execute(
        "UPDATE changesets SET reasons_json = ?2 WHERE change_id = ?1",
        params![change_id, json(&reasons)?],
    )?;
    Ok(())
}

pub fn set_items(
    connection: &Connection,
    change_id: &str,
    items: &[OutcomeItem],
) -> StoreResult<()> {
    connection.execute(
        "UPDATE changesets SET items_json = ?2 WHERE change_id = ?1",
        params![change_id, json(&items)?],
    )?;
    Ok(())
}

pub fn set_committed_revision(
    connection: &Connection,
    change_id: &str,
    revision_id: &str,
) -> StoreResult<()> {
    connection.execute(
        "UPDATE changesets SET committed_revision = ?2 WHERE change_id = ?1",
        params![change_id, revision_id],
    )?;
    Ok(())
}

pub fn set_confirmation(
    connection: &Connection,
    change_id: &str,
    confirmation: &Confirmation,
) -> StoreResult<()> {
    connection.execute(
        "UPDATE changesets SET confirmation_json = ?2, updated_at = ?3 WHERE change_id = ?1",
        params![change_id, json(confirmation)?, time::now()],
    )?;
    Ok(())
}

pub fn set_failure(connection: &Connection, change_id: &str, failure_key: &str) -> StoreResult<()> {
    connection.execute(
        "UPDATE changesets SET failure_key = ?2 WHERE change_id = ?1",
        params![change_id, failure_key],
    )?;
    Ok(())
}

/// Mark a change as saved to its Profile without anything applied to the
/// desktop; written in the commit's transaction.
pub fn set_saved_only(
    connection: &Connection,
    change_id: &str,
    reason: SavedOnlyReason,
) -> StoreResult<()> {
    connection.execute(
        "UPDATE changesets SET saved_only = ?2 WHERE change_id = ?1",
        params![change_id, reason.as_str()],
    )?;
    Ok(())
}

pub fn set_recovered(connection: &Connection, change_id: &str) -> StoreResult<()> {
    connection.execute(
        "UPDATE changesets SET recovered_at = ?2 WHERE change_id = ?1",
        params![change_id, time::now()],
    )?;
    Ok(())
}

// ---- operations -------------------------------------------------------------

pub struct NewOperation<'a> {
    pub change_id: &'a str,
    pub participant: &'a str,
    pub step: &'a str,
    pub request: &'a serde_json::Value,
}

/// Record an operation as started, before the request is sent.
pub fn start_operation(
    connection: &Connection,
    operation: &NewOperation<'_>,
) -> StoreResult<String> {
    let operation_id = ids::new(ids::OPERATION);
    let seq: u32 = connection.query_row(
        "SELECT COALESCE(MAX(seq), 0) + 1 FROM operations WHERE change_id = ?1",
        [operation.change_id],
        |row| row.get(0),
    )?;
    connection.execute(
        "INSERT INTO operations (operation_id, change_id, seq, participant, step, state, request_json,
            started_at, started_mono_ns) VALUES (?1, ?2, ?3, ?4, ?5, 'started', ?6, ?7, ?8)",
        params![
            operation_id,
            operation.change_id,
            seq,
            operation.participant,
            operation.step,
            json(operation.request)?,
            time::now(),
            time::monotonic_ns()
        ],
    )?;
    Ok(operation_id)
}

pub fn finish_operation(
    connection: &Connection,
    operation_id: &str,
    state: &str,
    readback: Option<&serde_json::Value>,
) -> StoreResult<()> {
    connection.execute(
        "UPDATE operations SET state = ?2, readback_json = ?3, ended_at = ?4, ended_mono_ns = ?5
         WHERE operation_id = ?1",
        params![
            operation_id,
            state,
            readback.map(json).transpose()?,
            time::now(),
            time::monotonic_ns()
        ],
    )?;
    Ok(())
}

pub fn operations(connection: &Connection, change_id: &str) -> StoreResult<Vec<OperationSummary>> {
    let mut statement = connection.prepare(
        "SELECT operation_id, seq, participant, step, state, started_at, ended_at FROM operations
         WHERE change_id = ?1 ORDER BY seq",
    )?;
    let rows = statement.query_map([change_id], |row| {
        Ok(OperationSummary {
            operation_id: row.get(0)?,
            seq: row.get(1)?,
            participant: row.get(2)?,
            step: row.get(3)?,
            state: row.get(4)?,
            started_at: row.get(5)?,
            ended_at: row.get(6)?,
        })
    })?;
    Ok(rows.collect::<Result<_, _>>()?)
}

/// Monotonic duration between the first operation of `from_step` and the end
/// of the last operation of `to_step`, for NFR-04 (prepared → committed).
pub fn step_span_ns(
    connection: &Connection,
    change_id: &str,
    from_step: &str,
    to_step: &str,
) -> StoreResult<Option<i64>> {
    Ok(connection
        .query_row(
            "SELECT (SELECT MAX(ended_mono_ns) FROM operations WHERE change_id = ?1 AND step = ?3)
                  - (SELECT MIN(started_mono_ns) FROM operations WHERE change_id = ?1 AND step = ?2)",
            params![change_id, from_step, to_step],
            |row| row.get(0),
        )
        .optional()?
        .flatten())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testing;
    use ditto_protocol::change::*;

    fn card() -> ChangeCard {
        ChangeCard {
            kind: "appearance".into(),
            title_key: "change.appearance".into(),
            title_args: Default::default(),
            items: vec![],
            footnote_key: None,
        }
    }

    #[test]
    fn illegal_transitions_are_refused_by_the_database() {
        let mut temp = testing::open("transitions");
        let origin = ChangeOrigin::Cli;
        let stored = temp
            .store
            .write(|tx| {
                insert(
                    tx,
                    &NewChange {
                        profile_id: "prf-x",
                        base_revision: "rev-x",
                        ops: &[],
                        mode: ChangeMode::Apply,
                        origin: &origin,
                        subject: "cli",
                        idempotency_key: Some("k1"),
                        request_operation_id: None,
                        card: &card(),
                        hot_swap_level: HotSwapLevel::Instant,
                    },
                )
            })
            .unwrap();
        let id = stored.record.change_id.clone();
        // draft → committed skips the machine: the trigger refuses it even
        // when the code asks for it directly.
        let skipped = temp.store.write(|tx| {
            tx.execute(
                "UPDATE changesets SET state = 'committed' WHERE change_id = ?1",
                [&id],
            )?;
            Ok(())
        });
        assert!(skipped.is_err());
        for (from, to) in [
            (ChangeState::Draft, ChangeState::Validated),
            (ChangeState::Validated, ChangeState::Prepared),
            (ChangeState::Prepared, ChangeState::Applying),
            (ChangeState::Applying, ChangeState::Verifying),
            (ChangeState::Verifying, ChangeState::Committed),
        ] {
            temp.store
                .write(|tx| transition(tx, &id, from, to))
                .unwrap();
        }
        let committed = temp.store.write(|tx| get(tx, &id)).unwrap();
        assert_eq!(committed.record.state, ChangeState::Committed);
        assert_eq!(committed.record.result, Some(ResultKind::Succeeded));
        // A terminal state has no successor, and history is not deletable.
        assert!(temp
            .store
            .write(|tx| transition(tx, &id, ChangeState::Committed, ChangeState::RollingBack))
            .is_err());
        assert!(temp
            .store
            .write(|tx| {
                tx.execute("DELETE FROM changesets", [])?;
                Ok(())
            })
            .is_err());
    }

    #[test]
    fn the_same_idempotency_key_cannot_make_a_second_change() {
        let mut temp = testing::open("idempotency");
        let origin = ChangeOrigin::Cli;
        let card = card();
        let new = |key| NewChange {
            profile_id: "prf-x",
            base_revision: "rev-x",
            ops: &[],
            mode: ChangeMode::Apply,
            origin: &origin,
            subject: "cli",
            idempotency_key: Some(key),
            request_operation_id: None,
            card: &card,
            hot_swap_level: HotSwapLevel::Instant,
        };
        let first = temp.store.write(|tx| insert(tx, &new("same"))).unwrap();
        assert!(temp.store.write(|tx| insert(tx, &new("same"))).is_err());
        let found = by_idempotency_key(temp.store.connection(), "same")
            .unwrap()
            .unwrap();
        assert_eq!(found.record.change_id, first.record.change_id);
    }
}
