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

fn secrets() -> Result<ditto_system::secrets::SecretStore, CoreError> {
    ditto_system::secrets::SecretStore::connect().map_err(secret_error)
}

/// Closed reasons in the message only; the secret never appears anywhere.
fn secret_error(error: ditto_system::secrets::SecretError) -> CoreError {
    use ditto_system::secrets::SecretError::*;
    match error {
        Unavailable => {
            CoreError::unavailable(UnavailableReason::SystemUnavailable, "keyring_unavailable")
        }
        Locked => CoreError::unavailable(UnavailableReason::SystemUnavailable, "keyring_locked"),
        Missing => CoreError::not_found("credential"),
        Failed(_) => CoreError::unavailable(UnavailableReason::SystemUnavailable, "keyring_failed"),
    }
}

fn credential_status(reference: &str) -> CredentialStatus {
    let (available, reason) = match secrets() {
        Err(_) => (false, Some("keyring_unavailable")),
        Ok(store) => match store.exists(reference) {
            Ok(true) => (true, None),
            Ok(false) => (false, Some("missing")),
            Err(ditto_system::secrets::SecretError::Locked) => (false, Some("locked")),
            Err(_) => (false, Some("keyring_unavailable")),
        },
    };
    CredentialStatus {
        credential_ref: reference.into(),
        available,
        reason: reason.map(String::from),
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
            // A repeated message key returns its turn; otherwise every
            // attached context must be this caller's and still unsent.
            let existing = core.read(|c| turns::by_client_message(c, &input.client_message_id))?;
            let references = if existing.is_some() {
                vec![]
            } else {
                core.contexts.references(&owner, &input.contexts)?
            };
            let ids = input.contexts.clone();
            let turn = write(core, call, move |s| turns::submit(s, &input, &references))?;
            if existing.is_none() {
                core.contexts.bind(&ids, &turn.turn_id);
            }
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
        "agent.turns.trace" => {
            let input: TurnIdInput = call.input()?;
            ok(core.read(|c| turns::trace(c, &input.turn_id))?)
        }
        "agent.turns.cancel" => {
            let input: TurnIdInput = call.input()?;
            let turn = write(core, call, move |s| turns::cancel(s, &input.turn_id))?;
            if turn.state.terminal() {
                core.contexts.release_turn(&turn.turn_id);
            }
            announce(core, &turn.session_id, Some(&turn));
            core.agent
                .notify("agent.controller.cancel", json!({"turn_id":turn.turn_id}));
            written(turn)
        }
        "agent.turns.claim" => {
            let input: TurnIdInput = call.input()?;
            let mut claimed = write(core, call, move |s| turns::claim(s, &input.turn_id, &owner))?;
            claimed.contexts = core.contexts.payloads(&claimed.turn.turn_id);
            announce(core, &claimed.turn.session_id, Some(&claimed.turn));
            core.agent
                .activity(&format!("turn:{}", claimed.turn.turn_id), true);
            written(claimed)
        }
        "agent.turns.complete" => {
            let input: TurnCompleteInput = call.input()?;
            let turn = write(core, call, move |s| turns::complete(s, &owner, &input))?;
            core.contexts.release_turn(&turn.turn_id);
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
                        || !(4..=16).contains(&login.user_code.len())
                        || !login
                            .user_code
                            .bytes()
                            .all(|b| b.is_ascii_uppercase() || b.is_ascii_digit() || b == b'-')
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
            let mut input: ApprovalRequestInput = call.input()?;
            let cap = catalog::contract(&input.capability_id)
                .ok_or_else(|| CoreError::not_found("approval capability"))?;
            let target = approval_target(core, &mut input)?;
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
            let mode = core.read(preferences::get)?.approval_mode;
            let preset = if mode == ApprovalMode::Never {
                Some(ApprovalDecision::Rejected)
            } else if !core.shell.approval_responder() || core.session_locked() {
                Some(ApprovalDecision::Unavailable)
            } else {
                None
            };
            let principal = caller.subject.0.clone();
            let approval = write(core, call, move |s| {
                approvals::request(s, &principal, &owner, input, preset, target)
            })?;
            if approval.decision.is_none() {
                if let Some(peer) = core.shell.peer() {
                    peer.notify("desktop.approval_requested", json!(approval));
                }
            }
            announce_turn(core, &approval.request.turn_id);
            written(approval)
        }
        "agent.turns.stream" => {
            let input: TurnStreamInput = call.input()?;
            if input.text.len() > 4096 {
                return Err(CoreError::invalid("stream batch exceeds 4 KiB"));
            }
            let turn = core.read(|c| turns::owner(c, &input.turn_id, &owner))?;
            if !matches!(turn.state, TurnState::Running | TurnState::AwaitingApproval) {
                return Err(CoreError::conflict(
                    ditto_protocol::ConflictReason::AlreadyTerminal,
                    "turn ended",
                ));
            }
            core.publish(ditto_protocol::DesktopEventPayload::ConversationDelta {
                session_id: turn.session_id,
                turn_id: turn.turn_id,
                text: input.text,
            });
            ok(ditto_protocol::Empty {})
        }
        "agent.credentials.create" => {
            let input: CredentialCreateInput = call.input()?;
            if input.provider != "direct-model"
                || input.secret.trim().is_empty()
                || input.secret.len() > 4096
                || input.secret.chars().any(char::is_control)
                || input.idempotency_key.is_empty()
            {
                return Err(CoreError::invalid("invalid credential"));
            }
            // The same request key names the same keyring item, so a retry
            // replaces rather than leaves an orphan behind.
            let reference = format!(
                "cred-{}",
                &ditto_protocol::jcs::digest(&json!(input.idempotency_key))
                    .trim_start_matches("sha256:")[..24]
            );
            secrets()?
                .store(&reference, "Ditto model API key", input.secret.as_bytes())
                .map_err(secret_error)?;
            crate::log::event(
                "credential.stored",
                &[("credential_ref", reference.as_str())],
            );
            written(CredentialStatus {
                credential_ref: reference,
                available: true,
                reason: None,
            })
        }
        "agent.credentials.status" => {
            let input: CredentialRefInput = call.input()?;
            ok(credential_status(&input.credential_ref))
        }
        "agent.credentials.delete" => {
            let input: CredentialRefInput = call.input()?;
            if !input.credential_ref.starts_with("cred-") {
                return Err(CoreError::invalid("not a Ditto credential"));
            }
            secrets()?
                .delete(&input.credential_ref)
                .map_err(secret_error)?;
            crate::log::event(
                "credential.deleted",
                &[("credential_ref", input.credential_ref.as_str())],
            );
            written(credential_status(&input.credential_ref))
        }
        "agent.credentials.resolve" => {
            // Only the current Agent, for the direct-model turn it is
            // running, and only the key that turn's settings name.
            let input: CredentialResolveInput = call.input()?;
            let turn = core.read(|c| turns::owner(c, &input.turn_id, &owner))?;
            if !matches!(turn.state, TurnState::Running | TurnState::AwaitingApproval) {
                return Err(CoreError::denied(
                    PermissionDeniedReason::PolicyDenied,
                    None,
                ));
            }
            let settings = core.read(preferences::get)?;
            let (
                Some(ProviderAuthentication::ApiKey { credential_ref }),
                Some(endpoint),
                "direct-model",
            ) = (
                settings.auth.as_ref(),
                settings.endpoint.clone(),
                settings.provider.as_str(),
            )
            else {
                return Err(CoreError::denied(
                    PermissionDeniedReason::PolicyDenied,
                    None,
                ));
            };
            let secret = secrets()?.lookup(credential_ref).map_err(secret_error)?;
            let secret = String::from_utf8(secret)
                .map_err(|_| CoreError::internal("credential is not text"))?;
            ok(CredentialResolveOutput { secret, endpoint })
        }
        "desktop.context.acquire" => {
            let input: ContextAcquireInput = call.input()?;
            let home = std::env::var_os("HOME")
                .map(std::path::PathBuf::from)
                .ok_or_else(|| {
                    CoreError::unavailable(
                        UnavailableReason::SystemUnavailable,
                        "no home directory",
                    )
                })?;
            let primary = core
                .session
                .with_adapter(|adapter| adapter.outputs())
                .ok()
                .and_then(|outputs| crate::outputs::primary(&outputs).map(|o| o.name.clone()));
            let reference =
                core.contexts
                    .acquire(&owner, &input, &home, core.session_locked(), primary)?;
            // Ids and kinds only: never a path, label or content in the log.
            crate::log::event(
                "context.acquired",
                &[
                    ("context_id", reference.context_id.as_str()),
                    ("bytes", &reference.bytes.to_string()),
                ],
            );
            ok(reference)
        }
        "desktop.context.preview" => {
            let input: ContextIdInput = call.input()?;
            ok(core.contexts.preview(&owner, &input.context_id)?)
        }
        "desktop.context.release" => {
            let input: ContextIdInput = call.input()?;
            core.contexts.release(&owner, &input.context_id)?;
            ok(ditto_protocol::Empty {})
        }
        "desktop.approvals.list" => {
            empty(call)?;
            let mut pending = core.read(approvals::pending)?;
            // An Agent sees only its own generation's requests.
            if caller.subject.as_str() == Subject::AGENT {
                pending.retain(|a| a.generation == owner);
            }
            ok(ApprovalsListOutput { approvals: pending })
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

/// The target an ask names, read by Core from the bound call's arguments:
/// deleting a Profile cannot be undone, so the person sees which one. The
/// arguments must hash to the intent the approval binds; they are not kept.
fn approval_target(
    core: &Core,
    input: &mut ApprovalRequestInput,
) -> Result<Option<String>, CoreError> {
    let arguments = input.arguments.take();
    if input.capability_id != catalog::PROFILES_DELETE {
        return Ok(None);
    }
    let arguments = arguments.ok_or_else(|| CoreError::invalid("deleting a Profile names it"))?;
    if ditto_protocol::jcs::digest(&arguments) != input.intent_hash {
        return Err(CoreError::invalid(
            "approval arguments do not match the tool intent",
        ));
    }
    let profile_id = arguments
        .get("profile_id")
        .and_then(serde_json::Value::as_str)
        .ok_or_else(|| CoreError::invalid("deleting a Profile names it"))?
        .to_string();
    let profile = core.read(move |c| ditto_store::profiles::get(c, &profile_id))?;
    Ok(Some(profile.name))
}
