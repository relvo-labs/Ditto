//! Core-only AI preferences, independent of Profile revisions. Secret values
//! are never accepted: authentication has a tagged reference-only schema.
use crate::{StoreError, StoreResult};
use ditto_protocol::agent::{AgentPreferences, PreferencesPatchInput, ProviderAuthentication};
use rusqlite::{Connection, OptionalExtension, Transaction};

pub fn get(connection: &Connection) -> StoreResult<AgentPreferences> {
    let data: Option<String> = connection
        .query_row(
            "SELECT settings_json FROM agent_preferences WHERE singleton=1",
            [],
            |r| r.get(0),
        )
        .optional()?;
    data.map(|v| serde_json::from_str(&v).map_err(Into::into))
        .unwrap_or_else(|| Ok(AgentPreferences::default()))
}
pub fn patch(tx: &Transaction<'_>, input: &PreferencesPatchInput) -> StoreResult<AgentPreferences> {
    let current = get(tx)?;
    if input.expected_revision != current.revision || input.settings.revision != current.revision {
        return Err(StoreError::Conflict("settings revision is stale".into()));
    }
    let mut next = input.settings.clone();
    if !["codex-app-server", "direct-model"].contains(&next.provider.as_str())
        || next.max_tool_calls == 0
        || next.max_tool_calls > 24
        || !(1_000..=120_000).contains(&next.turn_timeout_ms)
        || !next.retain_conversations
    {
        return Err(StoreError::Invalid(
            "unsupported backend, budget or retention policy".into(),
        ));
    }
    let reference = match next.auth.as_ref() {
        Some(ProviderAuthentication::CodexSubscription { connection_ref })
            if next.provider == "codex-app-server" =>
        {
            Some(connection_ref)
        }
        Some(ProviderAuthentication::ApiKey { credential_ref })
            if next.provider == "direct-model" =>
        {
            Some(credential_ref)
        }
        None => None,
        _ => {
            return Err(StoreError::Invalid(
                "authentication does not match backend".into(),
            ))
        }
    };
    if reference.is_some_and(|r| {
        r.is_empty()
            || r.len() > 128
            || !r
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || "-_:".contains(c))
    }) {
        return Err(StoreError::Invalid("invalid credential reference".into()));
    }
    for value in [next.model.as_ref(), next.reasoning_effort.as_ref()]
        .into_iter()
        .flatten()
    {
        if value.is_empty() || value.len() > 128 || value.chars().any(char::is_control) {
            return Err(StoreError::Invalid("invalid model option".into()));
        }
    }
    next.revision = current
        .revision
        .checked_add(1)
        .ok_or_else(|| StoreError::Invalid("revision exhausted".into()))?;
    let revision = i64::try_from(next.revision)
        .map_err(|_| StoreError::Invalid("revision exhausted".into()))?;
    tx.execute("INSERT INTO agent_preferences VALUES (1,?1,?2) ON CONFLICT(singleton) DO UPDATE SET revision=excluded.revision, settings_json=excluded.settings_json",
        rusqlite::params![revision, serde_json::to_string(&next)?])?;
    Ok(next)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn preferences_cas_does_not_change_profile_and_rejects_mixed_auth() {
        let mut tmp = crate::testing::open("preferences");
        let mut settings = get(tmp.store.connection()).unwrap();
        settings.enabled = true;
        let input = PreferencesPatchInput {
            expected_revision: 0,
            settings,
        };
        assert_eq!(tmp.store.write(|tx| patch(tx, &input)).unwrap().revision, 1);
        assert!(tmp.store.write(|tx| patch(tx, &input)).is_err());
        let mut bad = get(tmp.store.connection()).unwrap();
        bad.auth = Some(ProviderAuthentication::ApiKey {
            credential_ref: "key-1".into(),
        });
        assert!(tmp
            .store
            .write(|tx| patch(
                tx,
                &PreferencesPatchInput {
                    expected_revision: 1,
                    settings: bad
                }
            ))
            .is_err());
        assert_eq!(get(tmp.store.connection()).unwrap().revision, 1);
    }
}
