//! Jobs: package installation records (G1) and Core's work queue for trusted
//! background work (G2-CORE-05). The queue lives here so it survives a Core
//! restart; which jobs run, and their workers, are Core's scheduler's.

use ditto_protocol::{
    ids, jcs,
    services::{Job, JobState},
};
use rusqlite::{params, Connection, OptionalExtension, Row};

use crate::{
    error::{StoreError, StoreResult},
    time,
};

/// At most this many jobs wait; more is refused, never silently dropped.
pub const QUEUE_LIMIT: i64 = 32;

fn state_text(state: JobState) -> &'static str {
    match state {
        JobState::Queued => "queued",
        JobState::Running => "running",
        JobState::Cancelling => "cancelling",
        JobState::Succeeded => "succeeded",
        JobState::Failed => "failed",
        JobState::Cancelled => "cancelled",
    }
}

fn parse_state(text: &str) -> JobState {
    match text {
        "queued" => JobState::Queued,
        "running" => JobState::Running,
        "cancelling" => JobState::Cancelling,
        "succeeded" => JobState::Succeeded,
        "cancelled" => JobState::Cancelled,
        _ => JobState::Failed,
    }
}

const COLUMNS: &str = "job_id, kind, state, progress, result_json, error_key, idempotency_key, created_at, updated_at, owner, phase";

/// Kinds the pool runs (G2-CORE-05). Package installation is a separate,
/// synchronous path and cannot be stopped midway.
pub fn pool_kind(kind: &str) -> bool {
    kind != "plugins.install"
}

fn row(row: &Row<'_>) -> rusqlite::Result<Job> {
    let result: Option<String> = row.get(4)?;
    let kind: String = row.get(1)?;
    let state = parse_state(&row.get::<_, String>(2)?);
    Ok(Job {
        job_id: row.get(0)?,
        cancellable: pool_kind(&kind) && matches!(state, JobState::Queued | JobState::Running),
        kind,
        state,
        progress: row.get(3)?,
        result: result.and_then(|text| serde_json::from_str(&text).ok()),
        error_key: row.get(5)?,
        idempotency_key: row.get(6)?,
        created_at: row.get(7)?,
        updated_at: row.get(8)?,
        owner: row.get(9)?,
        phase: row.get(10)?,
    })
}

/// A package installation record, running from the start (G1 semantics).
pub fn create(
    connection: &Connection,
    kind: &str,
    idempotency_key: Option<&str>,
) -> StoreResult<Job> {
    let job_id = ids::new(ids::JOB);
    let now = time::now();
    connection.execute(
        "INSERT INTO jobs (job_id, kind, state, idempotency_key, created_at, updated_at)
         VALUES (?1, ?2, 'running', ?3, ?4, ?4)",
        params![job_id, kind, idempotency_key, now],
    )?;
    get(connection, &job_id)
}

/// Queue a pool job. The same key with the same kind and parameters returns
/// the job it created; with anything else it is a conflict.
pub fn enqueue(
    connection: &Connection,
    kind: &str,
    owner: &str,
    params: &serde_json::Value,
    idempotency_key: &str,
    deadline_ms: u64,
) -> StoreResult<Job> {
    let hash = jcs::digest(&serde_json::json!({"kind": kind, "params": params}));
    let existing: Option<(String, Option<String>)> = connection
        .query_row(
            "SELECT job_id, params_hash FROM jobs WHERE idempotency_key = ?1",
            [idempotency_key],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .optional()?;
    if let Some((job_id, old)) = existing {
        if old.as_deref() != Some(hash.as_str()) {
            return Err(StoreError::Conflict("job key has another payload".into()));
        }
        return get(connection, &job_id);
    }
    let waiting: i64 = connection.query_row(
        "SELECT count(*) FROM jobs WHERE state = 'queued'",
        [],
        |r| r.get(0),
    )?;
    if waiting >= QUEUE_LIMIT {
        return Err(StoreError::Invalid("the job queue is full".into()));
    }
    let job_id = ids::new(ids::JOB);
    let now = time::now();
    connection.execute(
        "INSERT INTO jobs (job_id, kind, state, idempotency_key, created_at, updated_at, owner, params_json, params_hash, deadline_ms)
         VALUES (?1, ?2, 'queued', ?3, ?4, ?4, ?5, ?6, ?7, ?8)",
        params![job_id, kind, idempotency_key, now, owner, serde_json::to_string(params)?, hash, deadline_ms as i64],
    )?;
    get(connection, &job_id)
}

/// Jobs holding a worker slot (installs included: they share the pool).
pub fn running_count(connection: &Connection) -> StoreResult<i64> {
    Ok(connection.query_row(
        "SELECT count(*) FROM jobs WHERE state IN ('running','cancelling')",
        [],
        |r| r.get(0),
    )?)
}

/// The oldest queued pool job, with its parameters and deadline.
pub fn next_queued(connection: &Connection) -> StoreResult<Option<(Job, serde_json::Value, u64)>> {
    let found: Option<(String, Option<String>, Option<i64>)> = connection
        .query_row(
            "SELECT job_id, params_json, deadline_ms FROM jobs WHERE state = 'queued' ORDER BY created_at, job_id LIMIT 1",
            [],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        )
        .optional()?;
    let Some((job_id, params, deadline)) = found else {
        return Ok(None);
    };
    let params = params
        .map(|text| serde_json::from_str(&text))
        .transpose()?
        .unwrap_or(serde_json::Value::Null);
    Ok(Some((
        get(connection, &job_id)?,
        params,
        deadline.unwrap_or(120_000).max(1) as u64,
    )))
}

/// queued → running, only if still queued (a cancel may have won).
pub fn start(connection: &Connection, job_id: &str, unit: &str) -> StoreResult<bool> {
    let now = time::now();
    Ok(connection.execute(
        "UPDATE jobs SET state = 'running', started_at = ?2, updated_at = ?2, unit = ?3, phase = 'starting' WHERE job_id = ?1 AND state = 'queued'",
        params![job_id, now, unit],
    )? == 1)
}

pub fn set_phase(
    connection: &Connection,
    job_id: &str,
    phase: &str,
    progress: Option<f64>,
) -> StoreResult<()> {
    connection.execute(
        "UPDATE jobs SET phase = ?2, progress = COALESCE(?3, progress), updated_at = ?4 WHERE job_id = ?1 AND state IN ('running','cancelling')",
        params![job_id, phase, progress, time::now()],
    )?;
    Ok(())
}

/// Ask to stop a job. A queued job is cancelled at once and never starts; a
/// running one becomes `cancelling` (the scheduler stops its worker). A
/// finished one is returned as it is.
pub fn request_cancel(connection: &Connection, job_id: &str) -> StoreResult<Job> {
    let job = get(connection, job_id)?;
    if !pool_kind(&job.kind) {
        return Err(StoreError::Invalid(
            "this job cannot be stopped midway".into(),
        ));
    }
    let now = time::now();
    match job.state {
        JobState::Queued => {
            connection.execute(
                "UPDATE jobs SET state = 'cancelled', cancel_requested = 1, error_key = 'job.cancelled', updated_at = ?2 WHERE job_id = ?1 AND state = 'queued'",
                params![job_id, now],
            )?;
        }
        JobState::Running => {
            connection.execute(
                "UPDATE jobs SET state = 'cancelling', cancel_requested = 1, updated_at = ?2 WHERE job_id = ?1 AND state = 'running'",
                params![job_id, now],
            )?;
        }
        _ => {}
    }
    get(connection, job_id)
}

pub fn cancel_requested(connection: &Connection, job_id: &str) -> StoreResult<bool> {
    Ok(connection.query_row(
        "SELECT cancel_requested FROM jobs WHERE job_id = ?1",
        [job_id],
        |r| r.get::<_, i64>(0),
    )? != 0)
}

/// End a job. A terminal job is not overwritten: the first outcome wins.
pub fn finish(
    connection: &Connection,
    job_id: &str,
    state: JobState,
    result: Option<&serde_json::Value>,
    error_key: Option<&str>,
) -> StoreResult<Job> {
    connection.execute(
        "UPDATE jobs SET state = ?2, result_json = ?3, error_key = ?4, progress = 1.0, phase = NULL, updated_at = ?5
         WHERE job_id = ?1 AND state NOT IN ('succeeded','failed','cancelled')",
        params![
            job_id,
            state_text(state),
            result.map(serde_json::to_string).transpose()?,
            error_key,
            time::now()
        ],
    )?;
    get(connection, job_id)
}

pub fn get(connection: &Connection, job_id: &str) -> StoreResult<Job> {
    connection
        .query_row(
            &format!("SELECT {COLUMNS} FROM jobs WHERE job_id = ?1"),
            [job_id],
            row,
        )
        .optional()?
        .ok_or_else(|| StoreError::NotFound(format!("job {job_id}")))
}

pub fn by_idempotency_key(connection: &Connection, key: &str) -> StoreResult<Option<Job>> {
    Ok(connection
        .query_row(
            &format!("SELECT {COLUMNS} FROM jobs WHERE idempotency_key = ?1"),
            [key],
            row,
        )
        .optional()?)
}

pub fn list(connection: &Connection, limit: u32) -> StoreResult<Vec<Job>> {
    let mut statement = connection.prepare(&format!(
        "SELECT {COLUMNS} FROM jobs ORDER BY job_id DESC LIMIT ?1"
    ))?;
    let rows = statement.query_map([limit], row)?;
    Ok(rows.collect::<Result<_, _>>()?)
}

/// At Core start: a job that was running lost its worker with Core, so it
/// failed as interrupted (its effects, if any, are not redone). Queued pool
/// jobs stay queued and run again; an install that never ran fails as
/// before (G1 semantics).
pub fn fail_interrupted(connection: &Connection) -> StoreResult<usize> {
    Ok(connection.execute(
        "UPDATE jobs SET state = CASE WHEN state = 'cancelling' THEN 'cancelled' ELSE 'failed' END,
                error_key = CASE WHEN state = 'cancelling' THEN 'job.cancelled' ELSE 'job.interrupted' END,
                phase = NULL, updated_at = ?1
         WHERE state IN ('running','cancelling') OR (state = 'queued' AND kind = 'plugins.install')",
        [time::now()],
    )?)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn the_queue_is_idempotent_bounded_cancellable_and_survives_restart() {
        let tmp = crate::testing::open("jobs");
        let connection = tmp.store.connection();
        let job = enqueue(
            connection,
            "test.spin",
            "agent",
            &json!({"ms": 10}),
            "k1",
            1_000,
        )
        .unwrap();
        assert_eq!(job.state, JobState::Queued);
        assert!(job.cancellable);
        assert_eq!(
            enqueue(
                connection,
                "test.spin",
                "agent",
                &json!({"ms": 10}),
                "k1",
                1_000
            )
            .unwrap()
            .job_id,
            job.job_id
        );
        assert!(enqueue(
            connection,
            "test.spin",
            "agent",
            &json!({"ms": 99}),
            "k1",
            1_000
        )
        .is_err());
        // A queued job cancelled never starts.
        assert_eq!(
            request_cancel(connection, &job.job_id).unwrap().state,
            JobState::Cancelled
        );
        assert!(!start(connection, &job.job_id, "unit").unwrap());
        // Running → cancelling; the real outcome may still arrive first, and
        // the first terminal outcome wins.
        let running = enqueue(connection, "test.spin", "cli", &json!({}), "k2", 1_000).unwrap();
        assert!(start(connection, &running.job_id, "unit-2").unwrap());
        assert_eq!(running_count(connection).unwrap(), 1);
        assert_eq!(
            request_cancel(connection, &running.job_id).unwrap().state,
            JobState::Cancelling
        );
        finish(
            connection,
            &running.job_id,
            JobState::Succeeded,
            Some(&json!({"done": true})),
            None,
        )
        .unwrap();
        assert_eq!(
            finish(connection, &running.job_id, JobState::Cancelled, None, None)
                .unwrap()
                .state,
            JobState::Succeeded
        );
        // Queue limit.
        for i in 0..QUEUE_LIMIT {
            enqueue(
                connection,
                "test.spin",
                "cli",
                &json!({}),
                &format!("q{i}"),
                1_000,
            )
            .unwrap();
        }
        assert!(enqueue(
            connection,
            "test.spin",
            "cli",
            &json!({}),
            "overflow",
            1_000
        )
        .is_err());
        // Restart: running fails as interrupted, queued stays queued.
        let (next, _, _) = next_queued(connection).unwrap().unwrap();
        start(connection, &next.job_id, "unit-3").unwrap();
        fail_interrupted(connection).unwrap();
        assert_eq!(
            get(connection, &next.job_id).unwrap().error_key.as_deref(),
            Some("job.interrupted")
        );
        assert_eq!(
            next_queued(connection).unwrap().unwrap().0.state,
            JobState::Queued
        );
        // Installs keep their G1 meaning: not stoppable.
        let install = create(connection, "plugins.install", None).unwrap();
        assert!(!install.cancellable);
        assert!(request_cancel(connection, &install.job_id).is_err());
    }
}
