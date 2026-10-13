//! Durable message acceptance and tool intent correlation. Historical tool
//! calls are queryable data, never an execution queue after a crash.
use crate::{conversations, preferences, time, Store, StoreError, StoreResult};
use ditto_protocol::{agent::*, change::ChangeState, ids, jcs};
use rusqlite::{Connection, OptionalExtension};
use serde_json::json;

pub fn get(connection: &Connection, id: &str) -> StoreResult<Turn> {
    let text: Option<String> = connection
        .query_row(
            "SELECT turn_json FROM agent_turns WHERE turn_id=?1",
            [id],
            |r| r.get(0),
        )
        .optional()?;
    serde_json::from_str(&text.ok_or_else(|| StoreError::NotFound("turn".into()))?)
        .map_err(Into::into)
}
pub fn queued(connection: &Connection) -> StoreResult<Vec<String>> {
    let mut query = connection.prepare(
        "SELECT turn_id FROM agent_turns WHERE state='queued' ORDER BY updated_at,turn_id LIMIT 32",
    )?;
    let result = query
        .query_map([], |row| row.get(0))?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(result)
}
fn update(store: &mut Store, turn: &Turn, owner: Option<&str>) -> StoreResult<()> {
    let state = serde_json::to_value(turn.state)?
        .as_str()
        .unwrap()
        .to_string();
    store.write(|tx|{tx.execute("UPDATE agent_turns SET state=?2,turn_json=?3,owner_connection=?4,updated_at=?5 WHERE turn_id=?1",
        rusqlite::params![turn.turn_id,state,serde_json::to_string(turn)?,owner,time::now()])?;Ok(())})
}
/// The turn a message key already created, if any.
pub fn by_client_message(connection: &Connection, key: &str) -> StoreResult<Option<Turn>> {
    let id: Option<String> = connection
        .query_row(
            "SELECT turn_id FROM agent_turns WHERE client_message_id=?1",
            [key],
            |r| r.get(0),
        )
        .optional()?;
    id.map(|id| get(connection, &id)).transpose()
}

/// `contexts` are the references of the context attached to the message;
/// the conversation keeps them (label, size, hash), never the content.
pub fn submit(
    store: &mut Store,
    input: &TurnSubmitInput,
    contexts: &[ContextReference],
) -> StoreResult<Turn> {
    if input.text.trim().is_empty()
        || input.text.len() > MAX_MESSAGE_BYTES
        || input.client_message_id.is_empty()
        || input.client_message_id.len() > 120
    {
        return Err(StoreError::Invalid("invalid message or message key".into()));
    }
    let settings = preferences::get(store.connection())?;
    if !settings.enabled {
        return Err(StoreError::Invalid(
            "AI is disabled; message has not been submitted".into(),
        ));
    }
    conversations::stat(store.connection(), store.paths(), &input.session_id)?;
    let hash = jcs::digest(&serde_json::to_value(input)?);
    let old: Option<(String, String)> = store
        .connection()
        .query_row(
            "SELECT turn_id,input_hash FROM agent_turns WHERE client_message_id=?1",
            [&input.client_message_id],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .optional()?;
    if let Some((id, old_hash)) = old {
        if hash != old_hash {
            return Err(StoreError::Conflict(
                "message key has another payload".into(),
            ));
        }
        return get(store.connection(), &id);
    }
    let queued:i64=store.connection().query_row("SELECT count(*) FROM agent_turns WHERE state IN ('queued','running','awaiting_approval','cancelling')",[],|r|r.get(0))?;
    if queued >= 32 {
        return Err(StoreError::Invalid("conversation queue is full".into()));
    }
    let seq = conversations::append_internal(
        store,
        &input.session_id,
        &format!("message:{}", input.client_message_id),
        SessionEventKind::UserMessage,
        if contexts.is_empty() {
            json!({"text":input.text,"client_message_id":input.client_message_id})
        } else {
            json!({"text":input.text,"client_message_id":input.client_message_id,"contexts":contexts})
        },
    )?;
    let turn = Turn {
        turn_id: format!("turn-{}", ids::ulid()),
        session_id: input.session_id.clone(),
        state: TurnState::Queued,
        created_at: time::now(),
        settings_revision: settings.revision,
        tool_calls: 0,
        operation_ids: vec![],
        error_reason: None,
    };
    store.write(|tx| {tx.execute("INSERT INTO agent_turns(turn_id,session_id,client_message_id,input_hash,state,turn_json,text_ref,updated_at) VALUES(?1,?2,?3,?4,'queued',?5,?6,?7)",
        rusqlite::params![turn.turn_id,turn.session_id,input.client_message_id,hash,serde_json::to_string(&turn)?,seq as i64,time::now()])?;Ok(())})?;
    Ok(turn)
}
pub fn claim(store: &mut Store, id: &str, owner: &str) -> StoreResult<TurnClaimOutput> {
    let mut turn = get(store.connection(), id)?;
    let settings = preferences::get(store.connection())?;
    if !settings.enabled {
        return Err(StoreError::Invalid("AI is disabled".into()));
    }
    if turn.state != TurnState::Queued {
        return Err(StoreError::Conflict("turn is not queued".into()));
    }
    // One active turn across the one Agent, even if several sessions queue.
    let active:bool=store.connection().query_row("SELECT EXISTS(SELECT 1 FROM agent_turns WHERE state IN ('running','awaiting_approval','cancelling'))",[],|r|r.get(0))?;
    if active {
        return Err(StoreError::Conflict(
            "Agent already has an active turn".into(),
        ));
    }
    conversations::open(store, &turn.session_id, owner)?;
    let seq: i64 = store.connection().query_row(
        "SELECT text_ref FROM agent_turns WHERE turn_id=?1",
        [id],
        |r| r.get(0),
    )?;
    let page = conversations::read(
        store.connection(),
        store.paths(),
        &SessionReadInput {
            session_id: turn.session_id.clone(),
            offset: seq as u64,
            limit: 1,
        },
    )?;
    let text = page
        .events
        .first()
        .and_then(|e| e.data.get("text"))
        .and_then(|v| v.as_str())
        .ok_or_else(|| StoreError::Corrupt("message is missing from conversation".into()))?
        .to_string();
    let recent_changes = recent_changes(store.connection(), &turn.session_id, 5)?;
    turn.state = TurnState::Running;
    turn.settings_revision = settings.revision;
    update(store, &turn, Some(owner))?;
    Ok(TurnClaimOutput {
        turn,
        text,
        message_seq: seq as u64,
        settings,
        recent_changes,
        contexts: vec![],
    })
}

/// The latest changes a conversation's tool calls produced, newest first,
/// from Core's own change records (never from the model's account of them).
pub fn recent_changes(
    connection: &Connection,
    session_id: &str,
    limit: usize,
) -> StoreResult<Vec<RecentChange>> {
    let rows: Vec<(String, String)> = {
        let mut query = connection.prepare(
            "SELECT i.change_id, i.turn_id FROM agent_tool_intents i JOIN agent_turns t ON t.turn_id=i.turn_id
             WHERE t.session_id=?1 AND i.change_id IS NOT NULL ORDER BY i.rowid DESC",
        )?;
        let rows = query
            .query_map([session_id], |r| Ok((r.get(0)?, r.get(1)?)))?
            .collect::<Result<Vec<_>, _>>()?;
        rows
    };
    let mut seen = std::collections::BTreeSet::new();
    let mut out = Vec::new();
    for (change_id, turn_id) in rows {
        if out.len() >= limit || !seen.insert(change_id.clone()) {
            continue;
        }
        let Ok(stored) = crate::changes::get(connection, &change_id) else {
            continue;
        };
        out.push(RecentChange {
            change_id,
            turn_id,
            state: stored.record.state,
            result: stored.record.result,
            items: stored.record.card.items,
        });
    }
    Ok(out)
}
pub fn owner(connection: &Connection, id: &str, expected: &str) -> StoreResult<Turn> {
    let turn = get(connection, id)?;
    let found: Option<String> = connection.query_row(
        "SELECT owner_connection FROM agent_turns WHERE turn_id=?1",
        [id],
        |r| r.get(0),
    )?;
    if found.as_deref() != Some(expected) {
        return Err(StoreError::Conflict("turn ownership lost".into()));
    }
    Ok(turn)
}
/// A running turn waits for a person (`awaiting_approval`) and goes back to
/// running once the approval is decided. Any other state is left alone: a
/// cancelling or finished turn never returns to running this way.
pub fn set_awaiting(
    store: &mut Store,
    id: &str,
    owner_id: &str,
    awaiting: bool,
) -> StoreResult<Turn> {
    let mut turn = owner(store.connection(), id, owner_id)?;
    let next = match (turn.state, awaiting) {
        (TurnState::Running, true) => TurnState::AwaitingApproval,
        (TurnState::AwaitingApproval, false) => TurnState::Running,
        _ => return Ok(turn),
    };
    turn.state = next;
    update(store, &turn, Some(owner_id))?;
    Ok(turn)
}
pub fn cancel(store: &mut Store, id: &str) -> StoreResult<Turn> {
    let mut turn = get(store.connection(), id)?;
    if turn.state.terminal() {
        return Ok(turn);
    }
    let owner: Option<String> = store.connection().query_row(
        "SELECT owner_connection FROM agent_turns WHERE turn_id=?1",
        [id],
        |r| r.get(0),
    )?;
    turn.state = if turn.state == TurnState::Queued {
        TurnState::Cancelled
    } else {
        TurnState::Cancelling
    };
    update(store, &turn, owner.as_deref())?;
    Ok(turn)
}
pub fn complete(store: &mut Store, owner_id: &str, input: &TurnCompleteInput) -> StoreResult<Turn> {
    let mut turn = owner(store.connection(), &input.turn_id, owner_id)?;
    if turn.state.terminal() {
        return Ok(turn);
    }
    if !input.state.terminal() {
        return Err(StoreError::Invalid("completion must be terminal".into()));
    }
    if input.error_reason.as_ref().is_some_and(|r| {
        ![
            "provider_unavailable",
            "provider_timeout",
            "rate_limited",
            "keyring_locked",
            "cancelled",
            "storage_full",
            "backend_unsupported",
            "interrupted",
            "tool_error",
        ]
        .contains(&r.as_str())
    }) {
        return Err(StoreError::Invalid("unknown turn failure reason".into()));
    }
    let unknown: bool = store.connection().query_row(
        "SELECT EXISTS(SELECT 1 FROM agent_tool_intents WHERE turn_id=?1 AND result_json IS NULL)",
        [&turn.turn_id],
        |r| r.get(0),
    )?;
    let outcomes = {
        let mut query=store.connection().prepare("SELECT result_json FROM agent_tool_intents WHERE turn_id=?1 AND result_json IS NOT NULL")?;
        let values = query
            .query_map([&turn.turn_id], |r| r.get::<_, String>(0))?
            .collect::<Result<Vec<_>, _>>()?;
        values
            .into_iter()
            .map(|v| serde_json::from_str::<serde_json::Value>(&v))
            .collect::<Result<Vec<_>, _>>()?
    };
    let failed = outcomes.iter().any(|v| v.get("error").is_some());
    // A proposal response may precede commit. Read the current authoritative
    // ChangeSet record, including IDs learned through ephemeral readbacks.
    let change_ids = {
        let mut query=store.connection().prepare("SELECT DISTINCT change_id FROM agent_tool_intents WHERE turn_id=?1 AND change_id IS NOT NULL")?;
        let rows = query
            .query_map([&turn.turn_id], |r| r.get::<_, String>(0))?
            .collect::<Result<Vec<_>, _>>()?;
        rows
    };
    let states = change_ids
        .iter()
        .map(|id| crate::changes::get(store.connection(), id).map(|c| c.record.state))
        .collect::<Vec<_>>();
    use ditto_protocol::change::ChangeState;
    let committed = states
        .iter()
        .any(|s| matches!(s, Ok(ChangeState::Committed)));
    let partial = states
        .iter()
        .any(|s| matches!(s, Ok(ChangeState::PartiallyApplied)));
    let pending = states.iter().any(|s| {
        !matches!(
            s,
            Ok(ChangeState::Committed
                | ChangeState::Rejected
                | ChangeState::Aborted
                | ChangeState::RolledBack
                | ChangeState::PartiallyApplied)
        )
    });
    let failed = failed
        || states.iter().any(|s| {
            matches!(
                s,
                Ok(ChangeState::Rejected | ChangeState::Aborted | ChangeState::RolledBack)
            )
        });
    let cancelled = turn.state == TurnState::Cancelling || input.state == TurnState::Cancelled;
    // A model/Agent cannot turn a refusal, pending operation, partial rollback
    // or a lost acknowledgement into a verified successful desktop task.
    turn.state = if unknown || pending {
        TurnState::Unknown
    } else if partial || (committed && (failed || cancelled || input.state == TurnState::Failed)) {
        TurnState::Partial
    } else if cancelled {
        TurnState::Cancelled
    } else if failed {
        TurnState::Failed
    } else {
        input.state
    };
    turn.error_reason = input.error_reason.clone();
    if failed && turn.error_reason.is_none() {
        turn.error_reason = Some("tool_error".into());
    }
    conversations::append_internal(
        store,
        &turn.session_id,
        &format!("end:{}", turn.turn_id),
        SessionEventKind::TurnEnd,
        json!({"turn_id":turn.turn_id,"state":turn.state}),
    )?;
    update(store, &turn, Some(owner_id))?;
    Ok(turn)
}
pub fn intent(
    store: &mut Store,
    owner_id: &str,
    input: &ToolIntentInput,
) -> StoreResult<ToolIntent> {
    let mut turn = owner(store.connection(), &input.turn_id, owner_id)?;
    let hash = jcs::digest(&input.arguments);
    let old:Option<(String,String,String,Option<String>)>=store.connection().query_row("SELECT intent_id,capability_id,payload_hash,result_json FROM agent_tool_intents WHERE turn_id=?1 AND call_id=?2",rusqlite::params![input.turn_id,input.tool_call_id],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?))).optional()?;
    if let Some((id, cap, old_hash, result)) = old {
        if cap != input.capability_id || old_hash != hash {
            return Err(StoreError::Conflict("tool key has another payload".into()));
        }
        return Ok(ToolIntent {
            intent_id: id,
            turn_id: turn.turn_id,
            tool_call_id: input.tool_call_id.clone(),
            capability_id: cap,
            payload_hash: hash,
            previous_result: result.map(|s| serde_json::from_str(&s)).transpose()?,
        });
    }
    let settings = preferences::get(store.connection())?;
    if !settings.enabled
        || turn.state != TurnState::Running
        || turn.tool_calls >= settings.max_tool_calls
    {
        return Err(StoreError::Conflict(
            "turn stopped or tool budget exhausted".into(),
        ));
    }
    if input.tool_call_id.is_empty()
        || input.tool_call_id.len() > 128
        || !input.arguments.is_object()
    {
        return Err(StoreError::Invalid("invalid tool call".into()));
    }
    let intent = ToolIntent {
        intent_id: format!("intent-{}", ids::ulid()),
        turn_id: turn.turn_id.clone(),
        tool_call_id: input.tool_call_id.clone(),
        capability_id: input.capability_id.clone(),
        payload_hash: hash,
        previous_result: None,
    };
    conversations::append_internal(
        store,
        &turn.session_id,
        &format!("intent:{}", intent.intent_id),
        SessionEventKind::ToolCall,
        json!({"turn_id":turn.turn_id,"call_id":input.tool_call_id,"capability_id":input.capability_id,"payload_hash":intent.payload_hash,"operation_id":intent.intent_id}),
    )?;
    turn.tool_calls += 1;
    turn.operation_ids.push(intent.intent_id.clone());
    store.write(|tx| {
        tx.execute("INSERT INTO agent_tool_intents(intent_id,turn_id,call_id,capability_id,payload_hash,owner_connection) VALUES(?1,?2,?3,?4,?5,?6)",rusqlite::params![intent.intent_id,turn.turn_id,input.tool_call_id,input.capability_id,intent.payload_hash,owner_id])?;
        tx.execute("UPDATE agent_turns SET turn_json=?2 WHERE turn_id=?1",rusqlite::params![turn.turn_id,serde_json::to_string(&turn)?])?;Ok(())
    })?;
    Ok(intent)
}
pub fn validate_intent(
    connection: &Connection,
    id: &str,
    owner_id: &str,
    cap: &str,
    args: &serde_json::Value,
) -> StoreResult<(Turn, String, Option<serde_json::Value>)> {
    if !preferences::get(connection)?.enabled {
        return Err(StoreError::Conflict("AI is disabled".into()));
    }
    let row:Option<(String,String,String,String,Option<String>)>=connection.query_row("SELECT turn_id,call_id,capability_id,payload_hash,result_json FROM agent_tool_intents WHERE intent_id=?1 AND owner_connection=?2",rusqlite::params![id,owner_id],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?,r.get(4)?))).optional()?;
    let (turn_id, call_id, expected_cap, hash, result) = row.ok_or_else(|| {
        StoreError::Conflict("tool intent is missing or belongs to another generation".into())
    })?;
    let turn = owner(connection, &turn_id, owner_id)?;
    if expected_cap != cap || hash != jcs::digest(args) {
        return Err(StoreError::Conflict("tool intent payload changed".into()));
    }
    if !matches!(turn.state, TurnState::Running | TurnState::AwaitingApproval) && result.is_none() {
        return Err(StoreError::Conflict("turn no longer accepts tools".into()));
    }
    Ok((
        turn,
        call_id,
        result.map(|s| serde_json::from_str(&s)).transpose()?,
    ))
}
pub fn record_result(store: &mut Store, id: &str, result: &serde_json::Value) -> StoreResult<()> {
    if serde_json::to_vec(result)?.len() > 262_144 {
        return Err(StoreError::Invalid(
            "tool result exceeds storage limit".into(),
        ));
    }
    let (turn_id, old, capability): (String, Option<String>, String) =
        store.connection().query_row(
            "SELECT turn_id,result_json,capability_id FROM agent_tool_intents WHERE intent_id=?1",
            [id],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        )?;
    if old.is_some() {
        return Ok(());
    }
    let turn = get(store.connection(), &turn_id)?;
    let change_id = result.pointer("/result/change_id").and_then(|v| v.as_str());
    conversations::append_internal(
        store,
        &turn.session_id,
        &format!("result:{id}"),
        SessionEventKind::ToolResult,
        json!({"turn_id":turn_id,"operation_id":id,"change_id":change_id,"verified":result.get("verified").and_then(|v|v.as_bool()).unwrap_or(false),"outcome":if result.get("error").is_some(){"failed"}else{"returned"}}),
    )?;
    let private_read = ditto_protocol::catalog::contract(&capability).is_some_and(|c| !c.writes)
        && result.get("error").is_none();
    let stored = if private_read {
        json!({"result":{"retained":false,"hash":jcs::digest(result)},"ephemeral":true,"verified":false})
    } else {
        result.clone()
    };
    store.write(|tx| {tx.execute("UPDATE agent_tool_intents SET result_json=?2,change_id=?3 WHERE intent_id=?1 AND result_json IS NULL",rusqlite::params![id,serde_json::to_string(&stored)?,change_id])?;Ok(())})
}
pub fn abandon(store: &mut Store, owner_id: &str, input: &ToolAbandonInput) -> StoreResult<()> {
    let (stored_owner,started,turn_id,result):(String,bool,String,Option<String>)=store.connection().query_row(
        "SELECT owner_connection,execution_started,turn_id,result_json FROM agent_tool_intents WHERE intent_id=?1",[&input.intent_id],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?)))?;
    owner(store.connection(), &turn_id, owner_id)?;
    if stored_owner != owner_id {
        return Err(StoreError::Conflict(
            "tool belongs to another generation".into(),
        ));
    }
    if result.is_some() {
        return Ok(());
    }
    if started {
        return Err(StoreError::Conflict(
            "tool was dispatched; its outcome must be queried".into(),
        ));
    }
    let name = match input.reason {
        ToolAbandonReason::PermissionDenied => "permission_denied",
        ToolAbandonReason::Cancelled => "cancelled",
    };
    record_result(
        store,
        &input.intent_id,
        &json!({"error":{"name":name,"message":"tool did not execute","data":{"executed":false}}}),
    )
}
/// Reserve a tool exactly once before dispatch. A lost result is unknown;
/// neither a concurrent request nor a replacement Agent may execute it again.
pub fn begin_execution(
    store: &mut Store,
    id: &str,
    owner_id: &str,
    cap: &str,
    args: &serde_json::Value,
) -> StoreResult<()> {
    let (_, _, result) = validate_intent(store.connection(), id, owner_id, cap, args)?;
    if result.is_some() {
        return Err(StoreError::Conflict("tool already has a result".into()));
    }
    store.write(|tx| {
        if tx.execute("UPDATE agent_tool_intents SET execution_started=1 WHERE intent_id=?1 AND owner_connection=?2 AND execution_started=0 AND result_json IS NULL",rusqlite::params![id,owner_id])?!=1 {
            return Err(StoreError::Conflict("tool was already dispatched; query its outcome".into()));
        }Ok(())
    })
}
/// The proven outcome for a dispatched call whose result never reached the
/// store: the ChangeSet its operation id produced, decided by boot recovery,
/// or `unknown_outcome`. It records; it never executes (G2-AGENT-10).
pub fn reconcile_dispatched(store: &mut Store) -> StoreResult<u32> {
    let mut query = store.connection().prepare(
        "SELECT intent_id FROM agent_tool_intents WHERE execution_started=1 AND result_json IS NULL",
    )?;
    let ids = query
        .query_map([], |r| r.get::<_, String>(0))?
        .collect::<Result<Vec<_>, _>>()?;
    drop(query);
    let mut settled = 0;
    for id in ids {
        let change = crate::changes::by_operation(store.connection(), &id)?.map(|c| c.record);
        let result = match change {
            Some(change) if change.state == ChangeState::Committed => json!({
                "result": {"change_id": change.change_id, "state": "committed", "committed_revision": change.committed_revision},
                "verified": true,
                "recovered": true,
            }),
            Some(change)
                if !matches!(
                    change.state,
                    ChangeState::Unknown | ChangeState::PartiallyApplied
                ) =>
            {
                json!({
                    "error": {"name": "not_applied", "message": "the change did not take effect", "data": {"change_id": change.change_id, "state": change.state}},
                    "recovered": true,
                })
            }
            change => json!({
                "error": {"name": "unknown_outcome", "message": "Core cannot tell whether this call took effect; it is not retried", "data": {"executed": "unknown", "change_id": change.map(|c| c.change_id)}},
                "recovered": true,
            }),
        };
        record_result(store, &id, &result)?;
        settled += 1;
    }
    Ok(settled)
}

/// One consistent snapshot of a turn and every tool call it made, each
/// with the ChangeSet and revision its operation id correlates to.
pub fn trace(connection: &Connection, id: &str) -> StoreResult<TurnTraceOutput> {
    let turn = get(connection, id)?;
    let mut query = connection.prepare(
        "SELECT intent_id,call_id,capability_id,execution_started,result_json FROM agent_tool_intents WHERE turn_id=?1 ORDER BY rowid",
    )?;
    let rows = query
        .query_map([id], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, String>(2)?,
                r.get::<_, bool>(3)?,
                r.get::<_, Option<String>>(4)?,
            ))
        })?
        .collect::<Result<Vec<_>, _>>()?;
    let mut tools = Vec::with_capacity(rows.len());
    for (intent_id, call_id, capability_id, started, result) in rows {
        let result: Option<serde_json::Value> =
            result.map(|s| serde_json::from_str(&s)).transpose()?;
        let change = crate::changes::by_operation(connection, &intent_id)?.map(|c| c.record);
        let outcome = match &result {
            None if !started => ToolOutcome::NotDispatched,
            None => ToolOutcome::Pending,
            Some(r)
                if r.pointer("/error/name").and_then(|v| v.as_str()) == Some("unknown_outcome") =>
            {
                ToolOutcome::Unknown
            }
            Some(r) if r.get("error").is_some() => ToolOutcome::Failed,
            Some(_) => ToolOutcome::Returned,
        };
        tools.push(ToolTrace {
            recovered: result
                .as_ref()
                .and_then(|r| r.get("recovered"))
                .and_then(|v| v.as_bool())
                .unwrap_or(false),
            change_id: change.as_ref().map(|c| c.change_id.clone()),
            change_state: change.as_ref().map(|c| c.state),
            committed_revision: change.and_then(|c| c.committed_revision),
            intent_id,
            call_id,
            capability_id,
            outcome,
        });
    }
    Ok(TurnTraceOutput { turn, tools })
}
pub fn interrupt_connection(store: &mut Store, owner_id: Option<&str>) -> StoreResult<()> {
    let mut query=store.connection().prepare("SELECT turn_id FROM agent_turns WHERE state IN ('running','awaiting_approval','cancelling') AND (?1 IS NULL OR owner_connection=?1)")?;
    let ids = query
        .query_map([owner_id], |r| r.get::<_, String>(0))?
        .collect::<Result<Vec<_>, _>>()?;
    drop(query);
    for id in ids {
        let mut turn = get(store.connection(), &id)?;
        turn.state = TurnState::Unknown;
        turn.error_reason = Some("interrupted".into());
        update(store, &turn, None)?;
    }
    Ok(())
}
pub fn cancel_queued(store: &mut Store) -> StoreResult<()> {
    for id in queued(store.connection())? {
        cancel(store, &id)?;
    }
    Ok(())
}
#[cfg(test)]
mod tests {
    use super::*;
    fn active(label: &str) -> (crate::testing::TempStore, Turn) {
        let mut t = crate::testing::open(label);
        let session = conversations::create(
            &mut t.store,
            &SessionCreateInput {
                title: "chat".into(),
                idempotency_key: "create".into(),
            },
        )
        .unwrap();
        let mut settings = preferences::get(t.store.connection()).unwrap();
        settings.enabled = true;
        t.store
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
        let turn = submit(
            &mut t.store,
            &TurnSubmitInput {
                session_id: session.session_id,
                text: "request".into(),
                client_message_id: "message".into(),
                contexts: vec![],
            },
            &[],
        )
        .unwrap();
        claim(&mut t.store, &turn.turn_id, "agent").unwrap();
        (t, turn)
    }
    fn tool(store: &mut Store, turn: &Turn, cap: &str) -> ToolIntent {
        intent(
            store,
            "agent",
            &ToolIntentInput {
                turn_id: turn.turn_id.clone(),
                tool_call_id: "call".into(),
                capability_id: cap.into(),
                arguments: json!({}),
            },
        )
        .unwrap()
    }
    fn second_tool(store: &mut Store, turn: &Turn, call: &str) -> ToolIntent {
        let intent = intent(
            store,
            "agent",
            &ToolIntentInput {
                turn_id: turn.turn_id.clone(),
                tool_call_id: call.into(),
                capability_id: "desktop.appearance.set".into(),
                arguments: json!({"call": call}),
            },
        )
        .unwrap();
        begin_execution(
            store,
            &intent.intent_id,
            "agent",
            "desktop.appearance.set",
            &json!({"call": call}),
        )
        .unwrap();
        intent
    }
    #[test]
    fn lost_results_are_settled_from_the_correlated_change_and_never_rerun() {
        use ditto_protocol::change::{ChangeCard, ChangeMode, ChangeOrigin, HotSwapLevel};
        let (mut t, turn) = active("reconcile");
        let committed = second_tool(&mut t.store, &turn, "committed");
        let rolled_back = second_tool(&mut t.store, &turn, "rolled-back");
        let lost = second_tool(&mut t.store, &turn, "lost");
        let reserved = tool(&mut t.store, &turn, "desktop.appearance.get");
        let card = ChangeCard {
            kind: "appearance".into(),
            title_key: "change.appearance".into(),
            title_args: Default::default(),
            items: vec![],
            footnote_key: None,
        };
        let mut path = vec![
            (ChangeState::Draft, ChangeState::Validated),
            (ChangeState::Validated, ChangeState::Prepared),
            (ChangeState::Prepared, ChangeState::Applying),
            (ChangeState::Applying, ChangeState::Verifying),
        ];
        for (intent, last) in [
            (&committed, ChangeState::Committed),
            (&rolled_back, ChangeState::RollingBack),
        ] {
            let change = t
                .store
                .write(|tx| {
                    crate::changes::insert(
                        tx,
                        &crate::changes::NewChange {
                            profile_id: "prf-x",
                            base_revision: "rev-x",
                            ops: &[],
                            mode: ChangeMode::Apply,
                            origin: &ChangeOrigin::Cli,
                            subject: "agent",
                            idempotency_key: None,
                            request_operation_id: Some(&intent.intent_id),
                            card: &card,
                            hot_swap_level: HotSwapLevel::Instant,
                        },
                    )
                })
                .unwrap();
            let id = change.record.change_id;
            path.push((ChangeState::Verifying, last));
            if last == ChangeState::RollingBack {
                path.push((ChangeState::RollingBack, ChangeState::RolledBack));
            }
            for (from, to) in &path {
                t.store
                    .write(|tx| crate::changes::transition(tx, &id, *from, *to))
                    .unwrap();
            }
            if last == ChangeState::Committed {
                t.store
                    .write(|tx| crate::changes::set_committed_revision(tx, &id, "rev-after"))
                    .unwrap();
            }
            path.truncate(4);
        }
        // Core died with all three in flight: the turn becomes unknown.
        interrupt_connection(&mut t.store, None).unwrap();
        assert_eq!(reconcile_dispatched(&mut t.store).unwrap(), 3);
        assert_eq!(reconcile_dispatched(&mut t.store).unwrap(), 0);
        let trace = trace(t.store.connection(), &turn.turn_id).unwrap();
        assert_eq!(trace.turn.state, TurnState::Unknown);
        let by_call = |call: &str| {
            trace
                .tools
                .iter()
                .find(|tool| tool.call_id == call)
                .unwrap()
                .clone()
        };
        let c = by_call("committed");
        assert_eq!(
            (
                c.outcome,
                c.recovered,
                c.change_state,
                c.committed_revision.as_deref()
            ),
            (
                ToolOutcome::Returned,
                true,
                Some(ChangeState::Committed),
                Some("rev-after")
            )
        );
        let r = by_call("rolled-back");
        assert_eq!(
            (r.outcome, r.change_state),
            (ToolOutcome::Failed, Some(ChangeState::RolledBack))
        );
        let l = by_call("lost");
        assert_eq!((l.outcome, l.change_id), (ToolOutcome::Unknown, None));
        assert_eq!(by_call("call").outcome, ToolOutcome::NotDispatched);
        assert_eq!(c.intent_id, committed.intent_id);
        let _ = (lost, reserved);
        // Settled calls stay settled: no new generation may dispatch them.
        assert!(begin_execution(
            &mut t.store,
            &c.intent_id,
            "agent",
            "desktop.appearance.set",
            &json!({"call":"committed"})
        )
        .is_err());
    }
    #[test]
    fn dispatched_tools_cannot_be_repeated_or_reported_unexecuted() {
        let (mut t, turn) = active("reservation");
        let intent = tool(&mut t.store, &turn, "desktop.appearance.get");
        begin_execution(
            &mut t.store,
            &intent.intent_id,
            "agent",
            &intent.capability_id,
            &json!({}),
        )
        .unwrap();
        assert!(begin_execution(
            &mut t.store,
            &intent.intent_id,
            "agent",
            &intent.capability_id,
            &json!({})
        )
        .is_err());
        assert!(abandon(
            &mut t.store,
            "agent",
            &ToolAbandonInput {
                intent_id: intent.intent_id,
                reason: ToolAbandonReason::Cancelled
            }
        )
        .is_err());
        interrupt_connection(&mut t.store, Some("agent")).unwrap();
        assert_eq!(
            get(t.store.connection(), &turn.turn_id).unwrap().state,
            TurnState::Unknown
        );
    }
    #[test]
    fn ephemeral_context_is_hashed_and_an_abandoned_tool_cannot_be_reported_successful() {
        let (mut t, turn) = active("private-context");
        let intent = tool(&mut t.store, &turn, "desktop.appearance.get");
        record_result(
            &mut t.store,
            &intent.intent_id,
            &json!({"result":{"private_title":"private-window-title"},"verified":true}),
        )
        .unwrap();
        let (_, _, stored) = validate_intent(
            t.store.connection(),
            &intent.intent_id,
            "agent",
            &intent.capability_id,
            &json!({}),
        )
        .unwrap();
        let stored = stored.unwrap();
        assert_eq!(stored["ephemeral"], true);
        assert!(!stored.to_string().contains("private-window-title"));
        let events = conversations::read(
            t.store.connection(),
            t.store.paths(),
            &SessionReadInput {
                session_id: turn.session_id.clone(),
                offset: 0,
                limit: 50,
            },
        )
        .unwrap();
        assert!(!serde_json::to_string(&events)
            .unwrap()
            .contains("private-window-title"));
        let second = intent_for_refusal(&mut t.store, &turn);
        abandon(
            &mut t.store,
            "agent",
            &ToolAbandonInput {
                intent_id: second.intent_id,
                reason: ToolAbandonReason::PermissionDenied,
            },
        )
        .unwrap();
        let result = complete(
            &mut t.store,
            "agent",
            &TurnCompleteInput {
                turn_id: turn.turn_id,
                state: TurnState::Succeeded,
                error_reason: None,
            },
        )
        .unwrap();
        assert_eq!(result.state, TurnState::Failed);
        assert_eq!(result.error_reason.as_deref(), Some("tool_error"));
    }
    fn intent_for_refusal(store: &mut Store, turn: &Turn) -> ToolIntent {
        intent(
            store,
            "agent",
            &ToolIntentInput {
                turn_id: turn.turn_id.clone(),
                tool_call_id: "refused".into(),
                capability_id: "desktop.windows.list".into(),
                arguments: json!({}),
            },
        )
        .unwrap()
    }
    #[test]
    fn completion_reads_change_authority_and_ai_off_fences_execution() {
        let (mut t, turn) = active("outcome-authority");
        let intent = tool(&mut t.store, &turn, "desktop.changes.propose");
        record_result(
            &mut t.store,
            &intent.intent_id,
            &json!({"result":{"change_id":"missing-change","state":"committed"},"verified":true}),
        )
        .unwrap();
        let result = complete(
            &mut t.store,
            "agent",
            &TurnCompleteInput {
                turn_id: turn.turn_id,
                state: TurnState::Succeeded,
                error_reason: None,
            },
        )
        .unwrap();
        assert_eq!(result.state, TurnState::Unknown);
        let (mut t, turn) = active("off-fence");
        let intent = tool(&mut t.store, &turn, "desktop.appearance.get");
        let mut settings = preferences::get(t.store.connection()).unwrap();
        let revision = settings.revision;
        settings.enabled = false;
        t.store
            .write(|tx| {
                preferences::patch(
                    tx,
                    &PreferencesPatchInput {
                        expected_revision: revision,
                        settings,
                    },
                )
            })
            .unwrap();
        assert!(begin_execution(
            &mut t.store,
            &intent.intent_id,
            "agent",
            &intent.capability_id,
            &json!({})
        )
        .is_err());
    }
    #[test]
    fn durable_acceptance_single_active_turn_and_no_tool_replay() {
        let mut t = crate::testing::open("turns");
        let session = conversations::create(
            &mut t.store,
            &SessionCreateInput {
                title: "chat".into(),
                idempotency_key: "create".into(),
            },
        )
        .unwrap();
        let mut settings = preferences::get(t.store.connection()).unwrap();
        settings.enabled = true;
        t.store
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
        let input = TurnSubmitInput {
            session_id: session.session_id,
            text: "left dock".into(),
            contexts: vec![],
            client_message_id: "msg-1".into(),
        };
        let turn = submit(&mut t.store, &input, &[]).unwrap();
        assert_eq!(
            submit(&mut t.store, &input, &[]).unwrap().turn_id,
            turn.turn_id
        );
        let claimed = claim(&mut t.store, &turn.turn_id, "agent-1").unwrap();
        assert_eq!(claimed.text, "left dock");
        let request = ToolIntentInput {
            turn_id: turn.turn_id.clone(),
            tool_call_id: "call-1".into(),
            capability_id: "desktop.changes.propose".into(),
            arguments: json!({"ops":[]}),
        };
        let intent = intent(&mut t.store, "agent-1", &request).unwrap();
        assert!(validate_intent(
            t.store.connection(),
            &intent.intent_id,
            "agent-2",
            &request.capability_id,
            &request.arguments
        )
        .is_err());
        let completed = complete(
            &mut t.store,
            "agent-1",
            &TurnCompleteInput {
                turn_id: turn.turn_id.clone(),
                state: TurnState::Succeeded,
                error_reason: None,
            },
        )
        .unwrap();
        assert_eq!(completed.state, TurnState::Unknown);
        assert!(claim(&mut t.store, &turn.turn_id, "agent-2").is_err());
    }
}
