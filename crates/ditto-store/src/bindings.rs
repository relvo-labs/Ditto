//! Capability bindings: which hostd entry provides which capability under
//! which lease. At most one active binding per capability (unique index).
//! Leases do not survive a Core restart: boot expires every active binding.

use rusqlite::{params, Connection, OptionalExtension};

use crate::{
    error::{StoreError, StoreResult},
    time,
};

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Binding {
    pub slot: Option<String>,
    pub entry_id: String,
    pub capability_id: String,
    pub lease_id: String,
    pub host_generation: u64,
}

pub fn activate(connection: &Connection, binding: &Binding) -> StoreResult<()> {
    let now = time::now();
    let inserted = connection.execute(
        "INSERT INTO capability_bindings (slot, entry_id, capability_id, lease_id, host_generation, state, created_at, updated_at)
         VALUES (?1, ?2, ?3, ?4, ?5, 'active', ?6, ?6)",
        params![
            binding.slot,
            binding.entry_id,
            binding.capability_id,
            binding.lease_id,
            binding.host_generation as i64,
            now
        ],
    );
    match inserted {
        Ok(_) => Ok(()),
        Err(error) => match StoreError::from(error) {
            StoreError::Conflict(_) => Err(StoreError::Conflict(format!(
                "{} already has an active provider",
                binding.capability_id
            ))),
            other => Err(other),
        },
    }
}

pub fn end(connection: &Connection, lease_id: &str, state: &str) -> StoreResult<bool> {
    Ok(connection.execute(
        "UPDATE capability_bindings SET state = ?2, updated_at = ?3 WHERE lease_id = ?1 AND state = 'active'",
        params![lease_id, state, time::now()],
    )? == 1)
}

pub fn expire_generation(connection: &Connection, generation: Option<u64>) -> StoreResult<usize> {
    Ok(connection.execute(
        "UPDATE capability_bindings SET state = 'expired', updated_at = ?2
         WHERE state = 'active' AND (?1 IS NULL OR host_generation = ?1)",
        params![generation.map(|value| value as i64), time::now()],
    )?)
}

pub fn active_for(connection: &Connection, capability_id: &str) -> StoreResult<Option<Binding>> {
    Ok(connection
        .query_row(
            "SELECT slot, entry_id, capability_id, lease_id, host_generation FROM capability_bindings
             WHERE capability_id = ?1 AND state = 'active'",
            [capability_id],
            |row| {
                Ok(Binding {
                    slot: row.get(0)?,
                    entry_id: row.get(1)?,
                    capability_id: row.get(2)?,
                    lease_id: row.get(3)?,
                    host_generation: row.get::<_, i64>(4)? as u64,
                })
            },
        )
        .optional()?)
}

pub fn count_active(connection: &Connection) -> StoreResult<u32> {
    Ok(connection.query_row(
        "SELECT COUNT(*) FROM capability_bindings WHERE state = 'active'",
        [],
        |row| row.get(0),
    )?)
}
