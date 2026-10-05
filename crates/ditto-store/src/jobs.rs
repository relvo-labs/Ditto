//! The minimal job record G1 needs for package installation. Not a work pool.

use ditto_protocol::{
    ids,
    services::{Job, JobState},
};
use rusqlite::{params, Connection, OptionalExtension, Row};

use crate::{
    error::{StoreError, StoreResult},
    time,
};

fn state_text(state: JobState) -> &'static str {
    match state {
        JobState::Queued => "queued",
        JobState::Running => "running",
        JobState::Succeeded => "succeeded",
        JobState::Failed => "failed",
        JobState::Cancelled => "cancelled",
    }
}

fn parse_state(text: &str) -> JobState {
    match text {
        "queued" => JobState::Queued,
        "running" => JobState::Running,
        "succeeded" => JobState::Succeeded,
        "cancelled" => JobState::Cancelled,
        _ => JobState::Failed,
    }
}

const COLUMNS: &str = "job_id, kind, state, progress, result_json, error_key, idempotency_key, created_at, updated_at";

fn row(row: &Row<'_>) -> rusqlite::Result<Job> {
    let result: Option<String> = row.get(4)?;
    Ok(Job {
        job_id: row.get(0)?,
        kind: row.get(1)?,
        state: parse_state(&row.get::<_, String>(2)?),
        progress: row.get(3)?,
        result: result.and_then(|text| serde_json::from_str(&text).ok()),
        error_key: row.get(5)?,
        idempotency_key: row.get(6)?,
        created_at: row.get(7)?,
        updated_at: row.get(8)?,
    })
}

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

pub fn finish(
    connection: &Connection,
    job_id: &str,
    state: JobState,
    result: Option<&serde_json::Value>,
    error_key: Option<&str>,
) -> StoreResult<Job> {
    connection.execute(
        "UPDATE jobs SET state = ?2, result_json = ?3, error_key = ?4, progress = 1.0, updated_at = ?5
         WHERE job_id = ?1",
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

/// A job still `running` when Core starts was interrupted: it failed.
pub fn fail_interrupted(connection: &Connection) -> StoreResult<usize> {
    Ok(connection.execute(
        "UPDATE jobs SET state = 'failed', error_key = 'job.interrupted', updated_at = ?1
         WHERE state IN ('queued', 'running')",
        [time::now()],
    )?)
}
