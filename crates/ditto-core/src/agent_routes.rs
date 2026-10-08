//! Core-owned conversation, preferences and Agent lifecycle RPCs. No provider
//! response is allowed to write a Profile or declare a desktop change verified.
use crate::{
    core::Core,
    error::CoreError,
    router::{coordinate, Call, Caller, Handled},
};
use ditto_protocol::{
    agent::*, catalog, rpc::CoreMode, ErrorName, PermissionDeniedReason, Subject, UnavailableReason,
};
use ditto_store::{approvals, conversations, preferences, turns, StoreResult};
use serde::Serialize;
use serde_json::json;
use std::{sync::Arc, time::Duration};

fn ok(value: impl Serialize) -> Handled {
    Ok((json!(value), false))
}
fn written(value: impl Serialize) -> Handled {
    Ok((json!(value), true))
}
fn write<T: Send + 'static>(
    core: &Core,
    call: &Call<'_>,
    work: impl FnOnce(&mut ditto_store::Store) -> StoreResult<T> + Send + 'static,
) -> Result<T, CoreError> {
    coordinate(core, call, move |c| work(c.store()))?.map_err(Into::into)
}
pub(crate) fn current(core: &Core, caller: &Caller) -> Result<(), CoreError> {
    if caller.subject.as_str() != Subject::AGENT
        || !core.agent.is_connection(&caller.connection_id)
        || caller.gone.load(std::sync::atomic::Ordering::SeqCst)
    {
        return Err(CoreError::identity(
            "a current Core-launched Agent connection is required",
        ));
    }
    Ok(())
}
/// Tell `conversations` subscribers that a session moved on. Only ids,
/// Core's cursor and the turn state travel; content needs its own read.
pub(crate) fn announce(core: &Core, session_id: &str, turn: Option<&Turn>) {
    let Ok(session) = core.read(|c| conversations::stat(c, &core.paths, session_id)) else {
        return;
    };
    core.publish(ditto_protocol::DesktopEventPayload::ConversationUpdated {
        session_id: session.session_id,
        next_seq: session.next_seq,
        turn_id: turn.map(|t| t.turn_id.clone()),
        turn_state: turn.map(|t| t.state),
        deleted: false,
    });
}

pub(crate) fn announce_turn(core: &Core, turn_id: &str) {
    if let Ok(turn) = core.read(|c| turns::get(c, turn_id)) {
        announce(core, &turn.session_id, Some(&turn));
    }
}

fn empty(call: &Call<'_>) -> Result<(), CoreError> {
    let _: ditto_protocol::Empty = call.input()?;
    Ok(())
}
fn provider(provider: &str) -> Result<(), CoreError> {
    if provider != "codex-app-server" {
        return Err(CoreError::invalid("provider is not installed"));
    }
    Ok(())
}
fn ensure(core: &Core) -> Result<AgentRuntimeStatus, CoreError> {
    if core.mode == CoreMode::Rescue {
        return Err(CoreError::unavailable(
            UnavailableReason::SystemUnavailable,
            "AI is unavailable in rescue mode",
        ));
    }
    core.agent.ensure().map_err(|_| {
        CoreError::unavailable(
            UnavailableReason::SystemUnavailable,
            "Agent could not start",
        )
    })
}
pub fn dispatch(core: &Arc<Core>, caller: &Caller, call: &Call<'_>) -> Handled {
    let method = call.contract.capability_id;
    if !core.agent_storage_ready && method != "agent.runtime.get" {
        return Err(CoreError::unavailable(
            UnavailableReason::StorageError,
            "conversation storage needs recovery",
        ));
    }
    if call.contract.scopes.contains(&catalog::scope::AGENT_WRITE) {
        current(core, caller)?;
    }
    let owner = caller.connection_id.clone();
    match method {
        "agent.sessions.create" => {
            let input: SessionCreateInput = call.input()?;
            let session = write(core, call, move |s| conversations::create(s, &input))?;
            announce(core, &session.session_id, None);
            written(session)
        }
        "agent.sessions.list" => {
            empty(call)?;
            ok(SessionsListOutput {
                sessions: core.read(conversations::list)?,
            })
        }
        "agent.sessions.stat" => {
            let input: SessionIdInput = call.input()?;
            ok(core.read(|c| conversations::stat(c, &core.paths, &input.session_id))?)
        }
        "agent.sessions.read" => {
            let input: SessionReadInput = call.input()?;
            ok(core.read(|c| conversations::read(c, &core.paths, &input))?)
        }
        "agent.sessions.open" => {
            let input: SessionIdInput = call.input()?;
            written(write(core, call, move |s| {
                conversations::open(s, &input.session_id, &owner)
            })?)
        }
        "agent.sessions.append" => {
            let input: SessionAppendInput = call.input()?;
            // Final state and tool evidence are exclusively Core-owned. An
            // Agent can persist model text, summaries and selected model only.
            if input.events.iter().any(|e| {
                !matches!(
                    e.kind,
                    SessionEventKind::AssistantMessage
                        | SessionEventKind::CompactionSummary
                        | SessionEventKind::ModelSelection
                )
            }) {
                return Err(CoreError::invalid("event is reserved for Core"));
            }
            let session = write(core, call, move |s| {
                conversations::append(s, &owner, &input)
            })?;
            announce(core, &session.session_id, None);
            written(session)
        }
        "agent.sessions.flush" => {
            let input: SessionWriteInput = call.input()?;
            written(write(core, call, move |s| {
                conversations::flush(s, &owner, &input)
            })?)
        }
        "agent.sessions.close" => {
            let input: SessionWriteInput = call.input()?;
            written(write(core, call, move |s| {
                conversations::close(s, &owner, &input)
            })?)
        }
        "agent.sessions.delete" => {
            let input: SessionIdInput = call.input()?;
            let session_id = input.session_id.clone();
            let deleted = write(core, call, move |s| {
                conversations::delete(s, &input.session_id)
            })?;
            core.publish(ditto_protocol::DesktopEventPayload::ConversationUpdated {
                session_id,
                next_seq: 0,
                turn_id: None,
                turn_state: None,
                deleted: true,
            });
            written(deleted)
        }
        "agent.settings.describe" => {
            empty(call)?;
            ok(core.read(preferences::get)?)
        }
        "agent.settings.patch" => {
            let input: PreferencesPatchInput = call.input()?;
            let settings = write(core, call, move |s| {
                let settings = s.write(|tx| preferences::patch(tx, &input))?;
                if !settings.enabled {
                    turns::cancel_queued(s)?;
                }
                Ok(settings)
            })?;
            core.agent.notify(
                "agent.controller.settings_changed",
                json!({"revision":settings.revision,"enabled":settings.enabled}),
            );
            if !settings.enabled {
                core.agent.stop();
            }
            written(settings)
        }
        "agent.turns.submit" => {
            let input: TurnSubmitInput = call.input()?;
            // Durable acceptance comes first. Startup failure leaves a visible
            // queued request, retrievable by its original message key.
            let turn = write(core, call, move |s| turns::submit(s, &input))?;
            announce(core, &turn.session_id, Some(&turn));
            if !turn.state.terminal() {
                let _ = ensure(core);
                core.agent.notify(
                    "agent.controller.turn_available",
                    json!({"turn_id":turn.turn_id}),
                );
            }
            written(turn)
        }
        "agent.turns.get" => {
            let input: TurnIdInput = call.input()?;
            ok(core.read(|c| turns::get(c, &input.turn_id))?)
        }
        "agent.turns.cancel" => {
            let input: TurnIdInput = call.input()?;
            let turn = write(core, call, move |s| turns::cancel(s, &input.turn_id))?;
            announce(core, &turn.session_id, Some(&turn));
            core.agent
                .notify("agent.controller.cancel", json!({"turn_id":turn.turn_id}));
            written(turn)
        }
        "agent.turns.claim" => {
            let input: TurnIdInput = call.input()?;
            let claimed = write(core, call, move |s| turns::claim(s, &input.turn_id, &owner))?;
            announce(core, &claimed.turn.session_id, Some(&claimed.turn));
            core.agent
                .activity(&format!("turn:{}", claimed.turn.turn_id), true);
            written(claimed)
        }
        "agent.turns.complete" => {
            let input: TurnCompleteInput = call.input()?;
            let turn = write(core, call, move |s| turns::complete(s, &owner, &input))?;
            announce(core, &turn.session_id, Some(&turn));
            core.agent
                .activity(&format!("turn:{}", turn.turn_id), false);
            written(turn)
        }
        "agent.tools.intent" => {
            let input: ToolIntentInput = call.input()?;
            let cap = catalog::contract(&input.capability_id)
                .ok_or_else(|| CoreError::not_found("capability"))?;
            // Configuration and desktop tools only. Model output cannot grant
            // permissions, modify provider settings or forge lifecycle records.
            if !input.capability_id.starts_with("desktop.")
                || input.capability_id.starts_with("desktop.approvals.")
                || cap.scopes.contains(&catalog::scope::PERMISSIONS_MANAGE)
            {
                return Err(CoreError::denied(
                    PermissionDeniedReason::PolicyDenied,
                    None,
                ));
            }
            let mut intent = write(core, call, move |s| turns::intent(s, &owner, &input))?;
            announce_turn(core, &intent.turn_id);
            // Only the capability's authorized readback path may deliver a
            // stored result. An intent response supplies correlation alone.
            intent.previous_result = None;
            written(intent)
        }
        "agent.tools.abandon" => {
            let input: ToolAbandonInput = call.input()?;
            write(core, call, move |s| turns::abandon(s, &owner, &input))?;
            written(ditto_protocol::Empty {})
        }
        "agent.runtime.get" => {
            empty(call)?;
            ok(core.agent.status())
        }
        "agent.runtime.ensure" => {
            empty(call)?;
            written(ensure(core)?)
        }
        "agent.runtime.ready" => {
            let _: AgentReadyInput = call.input()?;
            let status = core.agent.ready(&owner).map_err(CoreError::identity)?;
            // Explicitly queued messages survive startup delay; notifications
            // are a hint, never an execution log to replay.
            let queued = core.read(turns::queued)?;
            core.agent.notify(
                "agent.controller.turn_available",
                json!({"turn_ids":queued}),
            );
            written(status)
        }
        "agent.runtime.stop" => {
            empty(call)?;
            written(core.agent.stop())
        }
        "agent.providers.status"
        | "agent.providers.login"
        | "agent.providers.cancel_login"
        | "agent.providers.logout" => {
            let params = if method == "agent.providers.cancel_login" {
                let input: ProviderCancelLoginInput = call.input()?;
                provider(&input.provider)?;
                json!(input)
            } else {
                let input: ProviderLoginInput = call.input()?;
                provider(&input.provider)?;
                json!(input)
            };
            ensure(core)?;
            let peer = core.agent.peer().ok_or_else(|| {
                CoreError::unavailable(
                    UnavailableReason::SystemUnavailable,
                    "Agent is starting; retry after it is ready",
                )
            })?;
            let key = format!("provider:{}", call.id);
            core.agent.activity(&key, true);
            let result = peer.request(
                &method.replacen("agent.providers.", "agent.controller.provider.", 1),
                params,
                call.remaining().min(Duration::from_secs(30)),
            );
            core.agent.activity(&key, false);
            let value = result.map_err(|_| {
                CoreError::unavailable(
                    UnavailableReason::SystemUnavailable,
                    "model provider did not answer",
                )
            })?;
            match method {
                "agent.providers.status" => ok(serde_json::from_value::<ProviderStatus>(value)
                    .map_err(|_| CoreError::internal("invalid provider status"))?),
                "agent.providers.login" => {
                    let login: ProviderLoginOutput = serde_json::from_value(value)
                        .map_err(|_| CoreError::internal("invalid login response"))?;
                    if !login.auth_url.starts_with("https://auth.openai.com/")
                        || login.auth_url.len() > 4096
                        || login.expires_at_ms
                            > ditto_store::time::unix_millis_now().max(0) as u64 + 600_000
                    {
                        return Err(CoreError::internal("invalid login destination or lifetime"));
                    }
                    core.agent
                        .activity(&format!("login:{}", login.login_id), true);
                    written(login)
                }
                _ => written(
                    serde_json::from_value::<ProviderActionOutput>(value)
                        .map_err(|_| CoreError::internal("invalid provider action"))?,
                ),
            }
        }
        "desktop.approvals.request" => {
            current(core, caller)?;
            let input: ApprovalRequestInput = call.input()?;
            let cap = catalog::contract(&input.capability_id)
                .ok_or_else(|| CoreError::not_found("approval capability"))?;
            if input.resource != cap.scopes.join(",") {
                return Err(CoreError::invalid(
                    "approval resource does not match Core contract",
                ));
            }
            if cap.scopes.contains(&catalog::scope::PERMISSIONS_MANAGE)
                || !input.capability_id.starts_with("desktop.")
            {
                return Err(CoreError::denied(
                    PermissionDeniedReason::PolicyDenied,
                    None,
                ));
            }
            // Only a Shell that reported an approval surface can answer; a
            // bare Shell connection, or a locked session, means nobody would
            // see the prompt, so the request is recorded unavailable at once.
            let available = core.shell.approval_responder() && !core.session_locked();
            let principal = caller.subject.0.clone();
            let approval = write(core, call, move |s| {
                approvals::request(s, &principal, &owner, input, available)
            })?;
            if approval.decision.is_none() {
                if let Some(peer) = core.shell.peer() {
                    peer.notify("desktop.approval_requested", json!(approval));
                }
            }
            announce_turn(core, &approval.request.turn_id);
            written(approval)
        }
        "desktop.approvals.get" => {
            let input: ApprovalIdInput = call.input()?;
            let approval = core.read(|c| approvals::get(c, &input.request_id))?;
            if caller.subject.as_str() == Subject::AGENT && approval.generation != owner {
                return Err(CoreError::identity(
                    "approval belongs to another generation",
                ));
            }
            ok(approval)
        }
        "desktop.approvals.decide" => {
            let input: ApprovalDecideInput = call.input()?;
            let available = !core.session_locked();
            let approval = write(core, call, move |s| approvals::decide(s, &input, available))?;
            core.agent.notify(
                "agent.controller.approval_decided",
                json!({"request_id":approval.request_id,"decision":approval.decision}),
            );
            announce_turn(core, &approval.request.turn_id);
            written(approval)
        }
        _ => Err(CoreError::new(
            ErrorName::NotFound,
            "unknown Agent capability",
        )),
    }
}
