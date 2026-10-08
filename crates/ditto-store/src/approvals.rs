//! One-use authorization, bound to a durable tool intent and its connection.
//! An approval is never a persistent grant and cannot revive an old generation.
use crate::{time, turns, Store, StoreError, StoreResult};
use ditto_protocol::{agent::*, ids};
use rusqlite::{Connection, OptionalExtension};

pub fn get(connection: &Connection, id: &str) -> StoreResult<Approval> {
    let text: Option<String> = connection
        .query_row(
            "SELECT approval_json FROM agent_approvals WHERE request_id=?1",
            [id],
            |r| r.get(0),
        )
        .optional()?;
    serde_json::from_str(&text.ok_or_else(|| StoreError::NotFound("approval".into()))?)
        .map_err(Into::into)
}
/// Undecided, unexpired requests, oldest first.
pub fn pending(connection: &Connection) -> StoreResult<Vec<Approval>> {
    let mut query = connection.prepare(
        "SELECT approval_json FROM agent_approvals WHERE decided=0 AND expires_at_ms>?1 ORDER BY rowid",
    )?;
    let rows = query
        .query_map([time::unix_millis_now()], |r| r.get::<_, String>(0))?
        .collect::<Result<Vec<_>, _>>()?;
    rows.iter()
        .map(|text| serde_json::from_str(text).map_err(Into::into))
        .collect()
}

/// How long a person has to answer (plan/04/04 §1, D-39 proposal).
pub const EXPIRY_MS: u64 = 300_000;

/// `preset` decides at once instead of asking: `unavailable` when nobody can
/// answer, `rejected` when the person chose never to be asked.
pub fn request(
    store: &mut Store,
    principal: &str,
    owner: &str,
    input: ApprovalRequestInput,
    preset: Option<ApprovalDecision>,
) -> StoreResult<Approval> {
    let turn = turns::owner(store.connection(), &input.turn_id, owner)?;
    if turn.session_id != input.session_id
        || !matches!(turn.state, TurnState::Running | TurnState::AwaitingApproval)
        || input.resource.len() > 4096
        || input.resource.is_empty()
        || input.purpose.is_empty()
        || input.purpose.len() > 512
        || input.purpose.chars().any(char::is_control)
    {
        return Err(StoreError::Invalid("invalid approval target".into()));
    }
    let matching: bool = store.connection().query_row(
        "SELECT EXISTS(SELECT 1 FROM agent_tool_intents WHERE turn_id=?1 AND owner_connection=?2 AND capability_id=?3 AND payload_hash=?4 AND result_json IS NULL)",
        rusqlite::params![input.turn_id, owner, input.capability_id, input.intent_hash], |r| r.get(0)
    )?;
    if !matching {
        return Err(StoreError::Conflict(
            "approval is not bound to a pending tool intent".into(),
        ));
    }
    let old: Option<String> = store.connection().query_row(
        "SELECT approval_json FROM agent_approvals WHERE owner_connection=?1 AND expires_at_ms>?2 AND consumed=0 AND json_extract(approval_json,'$.request.turn_id')=?3 AND json_extract(approval_json,'$.request.capability_id')=?4 AND json_extract(approval_json,'$.request.intent_hash')=?5",
        rusqlite::params![owner, time::unix_millis_now(), input.turn_id, input.capability_id, input.intent_hash], |r|r.get(0)
    ).optional()?;
    if let Some(old) = old {
        return serde_json::from_str(&old).map_err(Into::into);
    }
    let approval = Approval {
        request_id: format!("approval-{}", ids::ulid()),
        principal: principal.into(),
        generation: owner.into(),
        request: input,
        expires_at_ms: time::unix_millis_now().max(0) as u64 + EXPIRY_MS,
        decision: preset,
        consumed: false,
    };
    store.write(|tx|{tx.execute("INSERT INTO agent_approvals(request_id,approval_json,principal,owner_connection,expires_at_ms,decided) VALUES(?1,?2,?3,?4,?5,?6)",
        rusqlite::params![approval.request_id,serde_json::to_string(&approval)?,principal,owner,approval.expires_at_ms as i64,approval.decision.is_some()])?;Ok(())})?;
    if approval.decision.is_none() {
        turns::set_awaiting(store, &approval.request.turn_id, owner, true)?;
    }
    Ok(approval)
}
pub fn decide(
    store: &mut Store,
    input: &ApprovalDecideInput,
    available: bool,
) -> StoreResult<Approval> {
    let mut approval = get(store.connection(), &input.request_id)?;
    if approval.request.intent_hash != input.intent_hash {
        return Err(StoreError::Conflict("approval payload changed".into()));
    }
    if let Some(decision) = approval.decision {
        if decision == input.decision {
            return Ok(approval);
        }
        return Err(StoreError::Conflict("approval already decided".into()));
    }
    let live = turns::owner(
        store.connection(),
        &approval.request.turn_id,
        &approval.generation,
    )
    .is_ok_and(|turn| matches!(turn.state, TurnState::Running | TurnState::AwaitingApproval));
    approval.decision = Some(
        if !available || !live || time::unix_millis_now().max(0) as u64 >= approval.expires_at_ms {
            ApprovalDecision::Unavailable
        } else {
            input.decision
        },
    );
    store.write(|tx|{tx.execute("UPDATE agent_approvals SET approval_json=?2,decided=1 WHERE request_id=?1 AND decided=0",
        rusqlite::params![approval.request_id,serde_json::to_string(&approval)?])?;Ok(())})?;
    if live {
        turns::set_awaiting(
            store,
            &approval.request.turn_id,
            &approval.generation,
            false,
        )?;
    }
    Ok(approval)
}
/// Called only in Core's common authorization path after identity, policy and
/// tool-intent validation. Revocation/lock checks happen immediately before it.
pub fn consume(
    store: &mut Store,
    owner: &str,
    turn_id: &str,
    capability: &str,
    hash: &str,
) -> StoreResult<bool> {
    let text:Option<String>=store.connection().query_row(
        "SELECT approval_json FROM agent_approvals WHERE owner_connection=?1 AND consumed=0 AND decided=1 AND expires_at_ms>?2 AND json_extract(approval_json,'$.request.turn_id')=?3 AND json_extract(approval_json,'$.request.capability_id')=?4 AND json_extract(approval_json,'$.request.intent_hash')=?5 AND json_extract(approval_json,'$.decision')='allowed-once' LIMIT 1",
        rusqlite::params![owner,time::unix_millis_now(),turn_id,capability,hash],|r|r.get(0)).optional()?;
    let Some(text) = text else { return Ok(false) };
    let mut approval: Approval = serde_json::from_str(&text)?;
    let turn = turns::owner(store.connection(), turn_id, owner)?;
    if !matches!(turn.state, TurnState::Running | TurnState::AwaitingApproval) {
        return Ok(false);
    }
    approval.consumed = true;
    store.write(|tx|{Ok(tx.execute("UPDATE agent_approvals SET consumed=1,approval_json=?2 WHERE request_id=?1 AND consumed=0",
        rusqlite::params![approval.request_id,serde_json::to_string(&approval)?])?==1)})
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{conversations, preferences};
    use serde_json::json;
    #[test]
    fn approval_is_one_use_and_fenced_by_generation_and_payload() {
        let mut tmp = crate::testing::open("approval");
        let store = &mut tmp.store;
        let session = conversations::create(
            store,
            &SessionCreateInput {
                title: "chat".into(),
                idempotency_key: "new".into(),
            },
        )
        .unwrap();
        let mut settings = preferences::get(store.connection()).unwrap();
        settings.enabled = true;
        store
            .write(|tx| {
                preferences::patch(
                    tx,
                    &PreferencesPatchInput {
                        expected_revision: 0,
                        settings,
                    },
                )
            })
            .unwrap();
        let turn = turns::submit(
            store,
            &TurnSubmitInput {
                session_id: session.session_id.clone(),
                client_message_id: "message".into(),
                text: "windows".into(),
                contexts: vec![],
            },
            &[],
        )
        .unwrap();
        turns::claim(store, &turn.turn_id, "generation-1").unwrap();
        let intent = turns::intent(
            store,
            "generation-1",
            &ToolIntentInput {
                turn_id: turn.turn_id.clone(),
                tool_call_id: "call".into(),
                capability_id: "desktop.windows.list".into(),
                arguments: json!({}),
            },
        )
        .unwrap();
        let input = ApprovalRequestInput {
            session_id: session.session_id,
            turn_id: turn.turn_id.clone(),
            capability_id: intent.capability_id.clone(),
            resource: "windows".into(),
            intent_hash: intent.payload_hash.clone(),
            purpose: "Arrange windows".into(),
        };
        let approval = request(store, "agent", "generation-1", input.clone(), None).unwrap();
        // A pending approval is visible as the turn waiting for a person; a
        // repeated request for the same intent returns the same approval.
        assert_eq!(
            turns::get(store.connection(), &turn.turn_id).unwrap().state,
            TurnState::AwaitingApproval
        );
        assert_eq!(
            request(store, "agent", "generation-1", input, None)
                .unwrap()
                .request_id,
            approval.request_id
        );
        assert!(!consume(
            store,
            "generation-1",
            &turn.turn_id,
            &intent.capability_id,
            &intent.payload_hash
        )
        .unwrap());
        let wrong = ApprovalDecideInput {
            request_id: approval.request_id.clone(),
            decision: ApprovalDecision::AllowedOnce,
            intent_hash: "other".into(),
        };
        assert!(decide(store, &wrong, true).is_err());
        decide(
            store,
            &ApprovalDecideInput {
                intent_hash: intent.payload_hash.clone(),
                ..wrong
            },
            true,
        )
        .unwrap();
        assert_eq!(
            turns::get(store.connection(), &turn.turn_id).unwrap().state,
            TurnState::Running
        );
        assert!(!consume(
            store,
            "generation-2",
            &turn.turn_id,
            &intent.capability_id,
            &intent.payload_hash
        )
        .unwrap());
        assert!(consume(
            store,
            "generation-1",
            &turn.turn_id,
            &intent.capability_id,
            &intent.payload_hash
        )
        .unwrap());
        assert!(!consume(
            store,
            "generation-1",
            &turn.turn_id,
            &intent.capability_id,
            &intent.payload_hash
        )
        .unwrap());
    }

    #[test]
    fn a_late_answer_is_unavailable_and_never_consumable() {
        let mut tmp = crate::testing::open("approval-late");
        let store = &mut tmp.store;
        let session = conversations::create(
            store,
            &SessionCreateInput {
                title: "chat".into(),
                idempotency_key: "late".into(),
            },
        )
        .unwrap();
        let mut settings = preferences::get(store.connection()).unwrap();
        settings.enabled = true;
        store
            .write(|tx| {
                preferences::patch(
                    tx,
                    &PreferencesPatchInput {
                        expected_revision: settings.revision,
                        settings: settings.clone(),
                    },
                )
            })
            .unwrap();
        let turn = turns::submit(
            store,
            &TurnSubmitInput {
                session_id: session.session_id.clone(),
                client_message_id: "late".into(),
                text: "windows".into(),
                contexts: vec![],
            },
            &[],
        )
        .unwrap();
        turns::claim(store, &turn.turn_id, "generation-1").unwrap();
        let intent = turns::intent(
            store,
            "generation-1",
            &ToolIntentInput {
                turn_id: turn.turn_id.clone(),
                tool_call_id: "late".into(),
                capability_id: "desktop.windows.list".into(),
                arguments: json!({}),
            },
        )
        .unwrap();
        let approval = request(
            store,
            "agent",
            "generation-1",
            ApprovalRequestInput {
                session_id: session.session_id,
                turn_id: turn.turn_id.clone(),
                capability_id: intent.capability_id.clone(),
                resource: "desktop.windows.read".into(),
                intent_hash: intent.payload_hash.clone(),
                purpose: "List windows".into(),
            },
            None,
        )
        .unwrap();
        assert_eq!(pending(store.connection()).unwrap().len(), 1);
        // The person answers after the request expired.
        let mut expired = approval.clone();
        expired.expires_at_ms = 1;
        store
            .write(|tx| {
                tx.execute(
                    "UPDATE agent_approvals SET approval_json=?2, expires_at_ms=1 WHERE request_id=?1",
                    rusqlite::params![approval.request_id, serde_json::to_string(&expired)?],
                )?;
                Ok(())
            })
            .unwrap();
        assert!(pending(store.connection()).unwrap().is_empty());
        let decided = decide(
            store,
            &ApprovalDecideInput {
                request_id: approval.request_id,
                decision: ApprovalDecision::AllowedOnce,
                intent_hash: intent.payload_hash.clone(),
            },
            true,
        )
        .unwrap();
        assert_eq!(decided.decision, Some(ApprovalDecision::Unavailable));
        assert!(!consume(
            store,
            "generation-1",
            &turn.turn_id,
            &intent.capability_id,
            &intent.payload_hash
        )
        .unwrap());
    }
}
