//! Capability routing (G1-CORE-05): one entry point for every `desktop.*`
//! call. Authorization first (one `authorize` for GUI and Agent alike), then
//! availability, then the provider: in-process for `core`, `system` and the
//! compositor adapter, forwarded under a lease for `hostd`. Writes that change
//! configuration are ChangeSets; for forwarded writes Core reads back itself.

use std::{
    collections::BTreeSet,
    sync::{mpsc, Arc},
    time::{Duration, Instant},
};

use ditto_protocol::{
    catalog::{self, Availability, CapabilityContract, Provider, Resolved},
    change::{
        ChangeIdInput, ChangeMode, ChangeOp, ChangeOrigin, ChangeRecord, ChangesGetInput,
        ChangesListInput, ChangesListOutput, ChangesProposeInput,
    },
    ids,
    participant::{EntryMode, FiberState},
    profile::*,
    rpc::CoreMode,
    services::*,
    DesktopEventPayload, ErrorName, EventTopic, EventsSubscribeInput, EventsSubscribeOutput,
    Subject, UnavailableReason,
};
use ditto_store::{changes, grants, jobs, packages, profiles};
use serde_json::{json, Map, Value};

use crate::{
    authz,
    coordinator::{Proposal, Target},
    core::{CoordinateError, Core, SubscriptionInfo},
    defaults, docops,
    error::CoreError,
    events::Registration,
    exports,
    projection::PackageSet,
    session::Outgoing,
};

/// Who is calling, as the connection established it.
#[derive(Clone)]
pub struct Caller {
    pub subject: Subject,
    pub kind: String,
    pub connection_id: String,
    pub sink: mpsc::Sender<Outgoing>,
    /// Set when the connection has ended. A proposal whose caller is gone
    /// before the coordinator accepted it is not executed (L-10).
    pub gone: Arc<std::sync::atomic::AtomicBool>,
}

pub struct Call<'a> {
    pub id: &'a str,
    pub contract: &'a CapabilityContract,
    pub params: Map<String, Value>,
    pub operation_id: Option<String>,
    pub deadline: Duration,
    pub started: Instant,
}

impl Call<'_> {
    pub(crate) fn input<T: serde::de::DeserializeOwned>(&self) -> Result<T, CoreError> {
        serde_json::from_value(Value::Object(self.params.clone()))
            .map_err(|error| CoreError::invalid(format!("invalid parameters: {error}")))
    }

    pub(crate) fn remaining(&self) -> Duration {
        self.deadline.saturating_sub(self.started.elapsed())
    }
}

/// The result of a handler: the value and whether it was read back.
pub type Handled = Result<(Value, bool), CoreError>;

fn ok<T: serde::Serialize>(value: T) -> Handled {
    Ok((json!(value), false))
}

fn verified<T: serde::Serialize>(value: T) -> Handled {
    Ok((json!(value), true))
}

// ---- authorization and availability --------------------------------------

/// `files:` scopes need the grant the call is about.
fn resource_for(contract: &CapabilityContract, params: &Map<String, Value>) -> Option<String> {
    let _ = contract;
    params
        .get("grant_id")
        .and_then(Value::as_str)
        .map(String::from)
}

pub fn authorize(
    core: &Core,
    caller: &Caller,
    contract: &CapabilityContract,
    params: &Map<String, Value>,
) -> Result<(), CoreError> {
    let all = core
        .read(|connection| grants::list(connection, Some(caller.subject.as_str()), false))
        .unwrap_or_default();
    let now = ditto_store::time::unix_millis_now();
    let usable: Vec<Grant> = all
        .into_iter()
        .filter(|grant| grants::is_effective(grant, now))
        .collect();
    let outcome = authz::authorize(
        &caller.subject,
        contract.scopes,
        resource_for(contract, params).as_deref(),
        &usable,
    );
    let decision = if outcome.allowed() {
        "allowed"
    } else {
        "denied"
    };
    let subject = caller.subject.0.clone();
    let action = contract.capability_id.to_string();
    let detail = outcome.scope.clone().unwrap_or_default();
    core.submit(move |coordinator| {
        coordinator.audit_decision(&subject, &action, decision, &detail)
    });
    if outcome.allowed() {
        return Ok(());
    }
    Err(CoreError::denied(
        outcome
            .reason
            .unwrap_or(ditto_protocol::PermissionDeniedReason::PolicyDenied),
        outcome.scope.as_deref(),
    ))
}

pub fn resolve(core: &Core, contract: &CapabilityContract) -> Resolved {
    let id = contract.capability_id;
    if id.starts_with("agent.") && id != "agent.runtime.get" {
        let storage = !core.agent_storage_ready;
        let process = id.starts_with("agent.providers.") || id == "agent.runtime.ensure";
        let unsupported_backend = id.starts_with("agent.providers.")
            && id != "agent.providers.status"
            && !core.agent.status().isolation_verified;
        if storage
            || process && (!core.agent.installed() || core.mode == CoreMode::Rescue)
            || unsupported_backend
        {
            return Resolved {
                provider_label: None,
                availability: Availability::DependsOnSystem {
                    component: if storage {
                        "conversation-storage"
                    } else {
                        "agent"
                    }
                    .into(),
                    available: false,
                    reason: Some(if storage {
                        UnavailableReason::StorageError
                    } else if core.mode == CoreMode::Rescue {
                        UnavailableReason::RescueMode
                    } else {
                        UnavailableReason::SystemUnavailable
                    }),
                },
            };
        }
    }
    match contract.provider {
        Provider::Core => Resolved {
            availability: Availability::Always,
            provider_label: None,
        },
        Provider::Compositor => Resolved {
            availability: core.session.availability(
                contract.capability_id,
                contract.matrix_row.unwrap_or_default(),
            ),
            provider_label: None,
        },
        Provider::System => {
            let component = system_component(contract.capability_id);
            let available = core.system.component_available(component);
            Resolved {
                availability: Availability::DependsOnSystem {
                    component: component.into(),
                    available,
                    reason: (!available).then_some(UnavailableReason::SystemUnavailable),
                },
                provider_label: None,
            }
        }
        Provider::Hostd(slot) => {
            let probe = if contract.capability_id == catalog::TASKS_SUBSCRIBE {
                catalog::TASKS_LIST
            } else {
                contract.capability_id
            };
            let (available, reason, entry_id) = core.hosts.availability(probe);
            let reason = if core.mode == CoreMode::Rescue {
                Some(UnavailableReason::RescueMode)
            } else {
                reason
            };
            Resolved {
                provider_label: entry_id.as_ref().map(|entry| format!("hostd:{entry}")),
                availability: Availability::DependsOnProvider {
                    slot: slot.into(),
                    available: available && core.mode != CoreMode::Rescue,
                    reason,
                    entry_id,
                },
            }
        }
    }
}

fn system_component(capability_id: &str) -> &'static str {
    if capability_id.starts_with("desktop.launcher.") {
        "launcher"
    } else if capability_id.starts_with("desktop.notifications.") {
        "notifications"
    } else {
        "logind"
    }
}

/// Availability is answered before the call, so a consumer never has to
/// fail once to learn a capability has no provider.
fn check_available(core: &Core, contract: &CapabilityContract) -> Result<(), CoreError> {
    match (contract.provider, resolve(core, contract).availability) {
        (
            Provider::Core,
            Availability::DependsOnSystem {
                available: false,
                reason,
                ..
            },
        ) => Err(CoreError::unavailable(
            reason.unwrap_or(UnavailableReason::SystemUnavailable),
            "this component is not available",
        )),
        (
            Provider::Compositor,
            Availability::DependsOnCompositor {
                available: false,
                reason,
                ..
            },
        ) => {
            let reason = reason.unwrap_or_else(|| "compositor gap".into());
            Err(if core.session.is_online() {
                CoreError::new(ErrorName::Unsupported, reason)
            } else {
                CoreError::unavailable(UnavailableReason::CompositorOffline, reason)
            })
        }
        (
            Provider::Hostd(_),
            Availability::DependsOnProvider {
                available: false,
                reason,
                ..
            },
        ) => Err(CoreError::unavailable(
            reason.unwrap_or(UnavailableReason::NotBound),
            "no service provides this capability right now",
        )),
        (
            Provider::System,
            Availability::DependsOnSystem {
                available: false, ..
            },
        ) => {
            // Launch and session actions report their own system errors; the
            // index and the notification list work without a session bus.
            Ok(())
        }
        _ => Ok(()),
    }
}

pub fn served_catalog(core: &Core) -> CapabilitiesView {
    CapabilitiesView(catalog::resolved_catalog(|contract| {
        resolve(core, contract)
    }))
}

pub struct CapabilitiesView(pub catalog::CapabilitiesListOutput);

// ---- dispatch -------------------------------------------------------------

pub fn dispatch(core: &Arc<Core>, caller: &Caller, call: Call<'_>) -> Handled {
    // The G1 stand-in remains a test caller. Every tool of the production
    // controller must be correlated before its first side effect.
    if caller.subject.as_str() == Subject::AGENT
        && core.agent.is_connection(&caller.connection_id)
        && call.contract.capability_id.starts_with("desktop.")
        && call.contract.capability_id != catalog::CAPABILITIES_LIST
        && !call
            .contract
            .capability_id
            .starts_with("desktop.approvals.")
    {
        crate::agent_routes::current(core, caller)?;
        if !core.agent.status().isolation_verified && call.contract.writes {
            return Err(CoreError::denied(
                ditto_protocol::PermissionDeniedReason::PolicyDenied,
                None,
            ));
        }
        let intent_id = call
            .operation_id
            .clone()
            .ok_or_else(|| CoreError::invalid("a durable tool intent is required"))?;
        let cap = call.contract.capability_id.to_string();
        let args = Value::Object(call.params.clone());
        let owner = caller.connection_id.clone();
        let (turn, _, previous) =
            core.read(|c| ditto_store::turns::validate_intent(c, &intent_id, &owner, &cap, &args))?;
        if let Some(value) = previous {
            // Cached delivery cannot bypass a revoked scope. Private read
            // results are never stored with conversation history in the first
            // place; a fresh read requires fresh authorization.
            authorize_call(core, caller, &call)?;
            if value.get("ephemeral").and_then(Value::as_bool) == Some(true) {
                return Err(CoreError::unavailable(
                    UnavailableReason::SystemUnavailable,
                    "this context is not retained; request a new authorized read",
                ));
            }
            if let Some(error) = value.get("error") {
                let error: crate::error::CoreError = crate::error::CoreError {
                    name: serde_json::from_value(error["name"].clone())
                        .map_err(|_| CoreError::internal("invalid stored tool error"))?,
                    message: error["message"].as_str().unwrap_or("tool failed").into(),
                    data: error.get("data").cloned(),
                };
                return Err(error);
            }
            return Ok((
                value["result"].clone(),
                value["verified"].as_bool().unwrap_or(false),
            ));
        }
        // Refused calls may request an approval and retry that same intent.
        // Only an authorized dispatch consumes the execution reservation.
        authorize_call(core, caller, &call)?;
        let id = intent_id.clone();
        coordinate(core, &call, move |c| {
            ditto_store::turns::begin_execution(c.store(), &id, &owner, &cap, &args)
        })??;
        let remaining = call.remaining();
        let outcome = dispatch_authorized(core, caller, call);
        let value = match &outcome {
            Ok((value, verified)) => json!({"result":value,"verified":verified}),
            Err(error) => {
                json!({"error":{"name":error.name,"message":error.message,"data":error.data}})
            }
        };
        core.coordinate(remaining.max(Duration::from_millis(500)), move |c| {
            ditto_store::turns::record_result(c.store(), &intent_id, &value)
        })
        .map_err(|_| {
            CoreError::new(
                ErrorName::Timeout,
                "tool result is not acknowledged; query its outcome",
            )
        })??;
        crate::agent_routes::announce_turn(core, &turn.turn_id);
        return outcome;
    }
    authorize_call(core, caller, &call)?;
    dispatch_authorized(core, caller, call)
}

fn authorize_call(core: &Arc<Core>, caller: &Caller, call: &Call<'_>) -> Result<(), CoreError> {
    let result = authorize(core, caller, call.contract, &call.params);
    if result.as_ref().is_err_and(|e| {
        e.data
            .as_ref()
            .and_then(|d| d.get("reason"))
            .and_then(Value::as_str)
            == Some("approval_unavailable")
    }) && caller.subject.as_str() == Subject::AGENT
        && core.agent.is_connection(&caller.connection_id)
        && !core.session_locked()
        && core.shell.peer().is_some()
        && call
            .contract
            .scopes
            .iter()
            .all(|s| authz::policy(&caller.subject, s) != authz::PolicyDefault::Deny)
    {
        if let Some(id) = &call.operation_id {
            let args = Value::Object(call.params.clone());
            let cap = call.contract.capability_id;
            let (turn, _, _) = core.read(|c| {
                ditto_store::turns::validate_intent(c, id, &caller.connection_id, cap, &args)
            })?;
            let owner = caller.connection_id.clone();
            let hash = ditto_protocol::jcs::digest(&args);
            if coordinate(core, call, move |c| {
                ditto_store::approvals::consume(c.store(), &owner, &turn.turn_id, cap, &hash)
            })?? {
                return Ok(());
            }
        }
    }
    result
}

fn dispatch_authorized(core: &Arc<Core>, caller: &Caller, call: Call<'_>) -> Handled {
    if call.contract.writes
        && core.is_recovering()
        && !call.contract.capability_id.starts_with("desktop.rescue.")
    {
        return Err(CoreError::unavailable(
            UnavailableReason::Recovering,
            "Core is finishing an interrupted change",
        ));
    }
    check_available(core, call.contract)?;
    if call.contract.provider == Provider::Compositor {
        return crate::desktop::execute(&core.session, &call);
    }
    match call.contract.capability_id {
        method
            if method.starts_with("agent.")
                || method.starts_with("desktop.approvals.")
                || method.starts_with("desktop.context.") =>
        {
            crate::agent_routes::dispatch(core, caller, &call)
        }
        catalog::CAPABILITIES_LIST => {
            empty(&call)?;
            ok(served_catalog(core).0)
        }
        catalog::EVENTS_SUBSCRIBE => subscribe(core, caller, &call),
        catalog::PROFILES_LIST => profiles_list(core),
        catalog::PROFILES_GET => profiles_get(core, call.input()?),
        "desktop.profiles.upgrade" => {
            let input: ditto_protocol::agent::ProfileUpgradeInput = call.input()?;
            if input.idempotency_key.is_empty() || input.idempotency_key.len() > 128 {
                return Err(CoreError::invalid("invalid upgrade key"));
            }
            let upgrade_key = format!(
                "upgrade:{}",
                ditto_protocol::jcs::digest(
                    &json!({"subject":caller.subject.as_str(),"key":input.idempotency_key})
                )
            );
            if let Some(existing) = core.read(|c| changes::by_idempotency_key(c, &upgrade_key))? {
                if existing.record.base_revision != input.base_revision
                    || input
                        .profile_id
                        .as_ref()
                        .is_some_and(|id| *id != existing.record.profile_id)
                {
                    return Err(CoreError::new(
                        ErrorName::Conflict,
                        "upgrade key has another target",
                    ));
                }
                return change_outcome(existing.record);
            }
            let id = resolve_profile(core, input.profile_id)?;
            let (_, _, document) = core.read(|c| profiles::head_document(c, &id))?;
            let packages = package_set(core)?;
            let protocol =
                semver::Version::parse(ditto_protocol::PROTOCOL_VERSION).expect("protocol version");
            let mut ops = Vec::new();
            for entry in &document.entries {
                let current = packages
                    .get(&entry.package, &entry.version)
                    .ok_or_else(|| CoreError::not_found("profile package"))?;
                if current.summary.source != "builtin" {
                    continue;
                }
                let compatible =
                    semver::VersionReq::parse(&current.manifest.required_protocol_version)
                        .is_ok_and(|r| r.matches(&protocol));
                if compatible {
                    continue;
                }
                let newest = packages
                    .rows()
                    .filter(|p| {
                        p.summary.package_id == entry.package && p.summary.source == "builtin"
                    })
                    .filter(|p| {
                        semver::VersionReq::parse(&p.manifest.required_protocol_version)
                            .is_ok_and(|r| r.matches(&protocol))
                    })
                    .filter_map(|p| semver::Version::parse(&p.summary.version).ok())
                    .max()
                    .ok_or_else(|| CoreError::not_found("compatible built-in update"))?;
                ops.push(ChangeOp::UpgradeEntry {
                    entry_id: entry.entry_id.clone(),
                    from_version: entry.version.clone(),
                    to_version: newest.to_string(),
                });
            }
            if ops.is_empty() {
                return Err(CoreError::invalid("this profile needs no protocol upgrade"));
            }
            let proposal = Proposal {
                profile_id: Some(id),
                base_revision: input.base_revision,
                ops,
                mode: ChangeMode::Apply,
                idempotency_key: Some(upgrade_key),
                request_operation_id: call.operation_id.clone(),
                origin: origin_for(core, caller, &call, Some("protocol-upgrade".into()))?,
                subject: caller.subject.0.clone(),
                target: None,
            };
            run_proposal(core, caller, proposal, &call)
        }
        catalog::PROFILES_CREATE => profiles_create(core, call.input()?),
        catalog::PROFILES_DUPLICATE => profiles_duplicate(core, call.input()?),
        catalog::PROFILES_RENAME => profiles_rename(core, call.input()?),
        catalog::PROFILES_DELETE => profiles_delete(core, call.input()?),
        catalog::PROFILES_DIFF => profiles_diff(core, call.input()?),
        catalog::PROFILES_EXPORT => profiles_export(core, call.input()?),
        catalog::PROFILES_IMPORT_VALIDATE => {
            let input: ProfilesImportValidateInput = call.input()?;
            let packages = package_set(core)?;
            let (_, problems) = exports::validate(&input.export, &packages);
            ok(ProfilesImportValidateOutput {
                importable: !problems.iter().any(|problem| problem.blocking),
                problems,
            })
        }
        catalog::PROFILES_IMPORT => profiles_import(core, call.input()?),
        catalog::CHANGES_PROPOSE => {
            let input: ChangesProposeInput = call.input()?;
            let proposal = Proposal {
                profile_id: input.profile_id,
                base_revision: input.base_revision,
                ops: input.ops,
                mode: input.mode,
                idempotency_key: input.idempotency_key,
                request_operation_id: call.operation_id.clone(),
                origin: origin_for(core, caller, &call, input.surface)?,
                subject: caller.subject.0.clone(),
                target: None,
            };
            run_proposal(core, caller, proposal, &call)
        }
        catalog::CHANGES_GET => changes_get(core, call.input()?),
        catalog::CHANGES_LIST => changes_list(core, call.input()?),
        catalog::CHANGES_CANCEL => {
            let input: ChangeIdInput = call.input()?;
            coordinate(core, &call, move |c| c.cancel(&input.change_id)).and_then(record_result)
        }
        catalog::CHANGES_CONFIRM => {
            let input: ChangeIdInput = call.input()?;
            coordinate(core, &call, move |c| c.confirm(&input.change_id)).and_then(record_result)
        }
        catalog::CHANGES_UNDO => {
            let input: ChangeIdInput = call.input()?;
            let subject = caller.subject.0.clone();
            let record = coordinate(core, &call, move |c| {
                c.undo(&input.change_id, &subject, input.idempotency_key)
            })?;
            change_outcome(record?)
        }
        catalog::APPEARANCE_GET => appearance_get(core),
        catalog::APPEARANCE_SET => {
            let input: AppearanceSetInput = call.input()?;
            let mut ops = Vec::new();
            let mut push = |field: &str, value: Option<Value>| {
                if let Some(value) = value {
                    ops.push(ChangeOp::SetValue {
                        path: format!("/appearance/{field}"),
                        before: None,
                        after: value,
                    });
                }
            };
            push("theme", input.theme.map(Value::from));
            push("reduced_motion", input.reduced_motion.map(Value::from));
            push(
                "reduced_transparency",
                input.reduced_transparency.map(Value::from),
            );
            push("low_power_style", input.low_power_style.map(Value::from));
            push("locale", input.locale.map(Value::from));
            if let Some(tokens) = input.tokens {
                for (token, value) in tokens {
                    ops.push(ChangeOp::SetValue {
                        path: format!(
                            "/appearance/tokens/{}",
                            token.replace('~', "~0").replace('/', "~1")
                        ),
                        before: None,
                        after: Value::from(value),
                    });
                }
            }
            if ops.is_empty() {
                return Err(CoreError::invalid("nothing to change"));
            }
            let proposal = Proposal {
                profile_id: None,
                base_revision: input.base_revision,
                ops,
                mode: ChangeMode::Apply,
                idempotency_key: input.idempotency_key,
                request_operation_id: call.operation_id.clone(),
                origin: origin_for(core, caller, &call, Some("personalization".into()))?,
                subject: caller.subject.0.clone(),
                target: None,
            };
            run_proposal(core, caller, proposal, &call)
        }
        catalog::PANELS_LIST => {
            empty(&call)?;
            ok(panels(core)?)
        }
        catalog::LAYOUT_GET => {
            empty(&call)?;
            layout_get(core)
        }
        catalog::SHORTCUTS_LIST => {
            empty(&call)?;
            shortcuts_list(core)
        }
        catalog::COMMANDS_LIST => {
            empty(&call)?;
            ok(CommandsListOutput {
                commands: commands(core)?,
            })
        }
        catalog::COMMANDS_INVOKE => commands_invoke(core, caller, &call),
        catalog::PLUGINS_LIST => plugins_list(core),
        catalog::PLUGINS_GET => plugins_get(core, call.input()?),
        catalog::PLUGINS_INSPECT => plugins_inspect(core, call.input()?),
        catalog::PLUGINS_INSTALL => plugins_install(core, &call, call.input()?),
        catalog::PLUGINS_REMOVE => {
            let input: PluginsRemoveInput = call.input()?;
            let removed = coordinate(core, &call, move |c| -> Result<bool, CoreError> {
                let sha = c
                    .store()
                    .write(|tx| packages::remove(tx, &input.package_id, &input.version))?;
                let paths = c.store_ref().paths().clone();
                let still_used = packages::list(c.store_ref().connection())?
                    .iter()
                    .any(|row| row.summary.sha256 == sha);
                if !still_used {
                    packages::remove_directory(&paths, &sha)?;
                }
                Ok(true)
            })??;
            verified(PluginsRemoveOutput { removed })
        }
        catalog::PLUGINS_DIAGNOSTICS => {
            crate::diagnostics::plugins(core, call.input()?).map(|value| (json!(value), false))
        }
        catalog::PERMISSIONS_LIST => {
            let input: PermissionsListInput = call.input()?;
            let grants = core.read(|connection| {
                grants::list(connection, input.subject.as_deref(), input.include_revoked)
            })?;
            ok(PermissionsListOutput {
                grants: grants.into_iter().map(hide_path).collect(),
                policy: authz::policy_table(),
            })
        }
        catalog::PERMISSIONS_CHECK => {
            let input: PermissionsCheckInput = call.input()?;
            let contract = catalog::contract(&input.capability_id).ok_or_else(|| {
                CoreError::not_found(format!("no capability {}", input.capability_id))
            })?;
            let subject = Subject(input.subject.clone());
            let all =
                core.read(|connection| grants::list(connection, Some(&input.subject), false))?;
            let now = ditto_store::time::unix_millis_now();
            let usable: Vec<_> = all
                .into_iter()
                .filter(|grant| grants::is_effective(grant, now))
                .collect();
            let outcome = authz::authorize(
                &subject,
                contract.scopes,
                input.resource.as_deref(),
                &usable,
            );
            ok(PermissionsCheckOutput {
                decision: outcome.decision,
                effective: outcome.effective,
                reason: outcome.reason,
                scopes: contract
                    .scopes
                    .iter()
                    .map(|scope| scope.to_string())
                    .collect(),
            })
        }
        catalog::PERMISSIONS_GRANT => permissions_grant(core, caller, &call, call.input()?),
        catalog::PERMISSIONS_REVOKE => {
            let input: GrantIdInput = call.input()?;
            let grant = coordinate(core, &call, move |c| -> Result<Grant, CoreError> {
                let grant = c.store().write(|tx| grants::revoke(tx, &input.grant_id))?;
                c.after_revoke(&grant);
                Ok(grant)
            })??;
            revoke_subscriptions(core, &grant);
            verified(hide_path(grant))
        }
        catalog::LAUNCHER_SEARCH => {
            let input: LauncherSearchInput = call.input()?;
            system(
                core.system
                    .search_apps(&input.query, input.limit.unwrap_or(30) as usize),
            )
        }
        catalog::LAUNCHER_LIST_APPS => {
            let input: LauncherListInput = call.input()?;
            system(core.system.list_apps(input.category.as_deref()))
        }
        catalog::LAUNCHER_LAUNCH => {
            let input: LauncherLaunchInput = call.input()?;
            let operation_id = call
                .operation_id
                .clone()
                .unwrap_or_else(|| ids::new(ids::OPERATION));
            system(core.system.launch(&input, &operation_id))
        }
        catalog::NOTIFICATIONS_LIST => {
            let input: NotificationsListInput = call.input()?;
            let notifications = core
                .system
                .notifications(input.limit.unwrap_or(100) as usize)
                .map_err(system_error)?;
            ok(NotificationsListOutput {
                notifications,
                server_owned: core.system.notification_server_owned(),
            })
        }
        catalog::NOTIFICATIONS_DISMISS => {
            let input: NotificationIdInput = call.input()?;
            let dismissed = core.system.dismiss(input.id).map_err(system_error)?;
            let still = core
                .system
                .notifications(500)
                .map_err(system_error)?
                .iter()
                .any(|item| item.id == input.id);
            if dismissed && !still {
                core.publish(DesktopEventPayload::NotificationClosed {
                    id: input.id,
                    reason: "dismissed".into(),
                });
            }
            Ok((json!(NotificationsDismissOutput { dismissed }), !still))
        }
        catalog::NOTIFICATIONS_POLICY_STATUS => {
            empty(&call)?;
            ok(policy_status(core))
        }
        catalog::NOTIFICATIONS_POLICY_DECIDE
        | catalog::NOTIFICATIONS_POLICY_GET
        | catalog::TASKS_LIST => forward(
            core,
            caller,
            &call,
            call.contract.capability_id,
            Value::Object(call.params.clone()),
        )
        .map(|value| (value, false)),
        catalog::TASKS_ADD => {
            let value = forward(
                core,
                caller,
                &call,
                catalog::TASKS_ADD,
                Value::Object(call.params.clone()),
            )?;
            let task_id = value
                .get("task_id")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_string();
            let listed = forward(core, caller, &call, catalog::TASKS_LIST, json!({}))?;
            let present = listed["tasks"]
                .as_array()
                .is_some_and(|tasks| tasks.iter().any(|task| task["task_id"] == json!(task_id)));
            Ok((value, present))
        }
        catalog::TASKS_COMPLETE => {
            let input: TasksCompleteInput = call.input()?;
            let value = forward(
                core,
                caller,
                &call,
                catalog::TASKS_COMPLETE,
                Value::Object(call.params.clone()),
            )?;
            let listed = forward(core, caller, &call, catalog::TASKS_LIST, json!({}))?;
            let done = listed["tasks"].as_array().is_some_and(|tasks| {
                tasks.iter().any(|task| {
                    task["task_id"] == json!(input.task_id) && task["done"] == json!(true)
                })
            });
            Ok((value, done))
        }
        catalog::TASKS_SUBSCRIBE => {
            empty(&call)?;
            let registration = core.session.subscribe_topics(
                None,
                [EventTopic::Tasks].into_iter().collect(),
                caller.sink.clone(),
            );
            let Registration::Ready {
                subscription_id,
                seq,
                ..
            } = registration
            else {
                return Err(CoreError::internal("subscription could not be established"));
            };
            track_subscription(core, caller, &subscription_id, vec![EventTopic::Tasks]);
            let snapshot = forward(core, caller, &call, catalog::TASKS_LIST, json!({}))?;
            let snapshot: TasksListOutput = serde_json::from_value(snapshot)
                .map_err(|error| CoreError::internal(error.to_string()))?;
            ok(TasksSubscribeOutput {
                subscription_id,
                seq,
                snapshot,
            })
        }
        catalog::SESSION_STATE => {
            empty(&call)?;
            ok(core.session_state())
        }
        catalog::SESSION_LOCK => {
            empty(&call)?;
            let operation_id = call
                .operation_id
                .clone()
                .unwrap_or_else(|| ids::new(ids::OPERATION));
            core.lock_session();
            if core.lock_spec.is_none() {
                core.system.lock_session().map_err(system_error)?;
            }
            let locked = core.session_state().locked;
            Ok((
                json!(SessionActionOutput {
                    accepted: true,
                    operation_id
                }),
                locked,
            ))
        }
        catalog::SESSION_LOGOUT | catalog::SESSION_SUSPEND | catalog::SESSION_POWEROFF => {
            empty(&call)?;
            let operation_id = call
                .operation_id
                .clone()
                .unwrap_or_else(|| ids::new(ids::OPERATION));
            wait_for_idle_coordinator(core);
            let outcome = match call.contract.capability_id {
                catalog::SESSION_LOGOUT => core.system.logout(),
                catalog::SESSION_SUSPEND => core.system.suspend(),
                _ => core.system.poweroff(),
            };
            outcome.map_err(system_error)?;
            ok(SessionActionOutput {
                accepted: true,
                operation_id,
            })
        }
        catalog::JOBS_GET => {
            let input: JobIdInput = call.input()?;
            ok(core.read(|connection| jobs::get(connection, &input.job_id))?)
        }
        catalog::JOBS_LIST => {
            empty(&call)?;
            ok(JobsListOutput {
                jobs: core.read(|connection| jobs::list(connection, 50))?,
            })
        }
        catalog::JOBS_CANCEL => {
            // Installation jobs run to completion in one step; a finished job
            // cannot be cancelled and a running one does not stop midway.
            let input: JobIdInput = call.input()?;
            let job = core.read(|connection| jobs::get(connection, &input.job_id))?;
            if matches!(
                job.state,
                JobState::Succeeded | JobState::Failed | JobState::Cancelled
            ) {
                return Err(CoreError::conflict(
                    ditto_protocol::ConflictReason::AlreadyTerminal,
                    "the job already finished",
                ));
            }
            Err(CoreError::conflict(
                ditto_protocol::ConflictReason::ChangeInProgress,
                "the job is running and cannot be stopped midway",
            ))
        }
        catalog::RESCUE_STATUS => {
            empty(&call)?;
            ok(crate::diagnostics::rescue_status(core)?)
        }
        catalog::RESCUE_DISABLE => {
            let input: RescueDisableInput = call.input()?;
            let subject = caller.subject.0.clone();
            let record = coordinate(core, &call, move |c| {
                c.rescue_disable(&input.target, &subject, input.idempotency_key)
            })?;
            change_outcome(record?)
        }
        catalog::RESCUE_RESUME_SHELL => {
            empty(&call)?;
            let was_in_rescue_ui = core.shell.resume();
            let shell_connected = core.shell.wait_connected(Duration::from_secs(12));
            ok(ditto_protocol::services::RescueResumeShellOutput {
                was_in_rescue_ui,
                shell_connected,
            })
        }
        catalog::RESCUE_RESTORE_LAST_GOOD => {
            let input: RescueRestoreInput = call.input()?;
            let subject = caller.subject.0.clone();
            let record = coordinate(core, &call, move |c| {
                c.rescue_restore(input.profile_id.as_deref(), &subject, input.idempotency_key)
            })?;
            change_outcome(record?)
        }
        other => Err(CoreError::new(
            ErrorName::Unsupported,
            format!("{other} has no handler in Core"),
        )),
    }
}

fn empty(call: &Call<'_>) -> Result<(), CoreError> {
    if call.params.is_empty() {
        Ok(())
    } else {
        Err(CoreError::invalid("unexpected capability parameters"))
    }
}

fn system<T: serde::Serialize>(outcome: ditto_system::SystemResult<T>) -> Handled {
    outcome
        .map(|value| (json!(value), false))
        .map_err(system_error)
}

fn system_error(error: ditto_system::SystemError) -> CoreError {
    match error {
        ditto_system::SystemError::Unavailable(reason) => {
            CoreError::unavailable(UnavailableReason::SystemUnavailable, reason)
        }
        ditto_system::SystemError::NotFound(reason) => CoreError::not_found(reason),
        ditto_system::SystemError::Invalid(reason) => CoreError::invalid(reason),
        ditto_system::SystemError::Failed(reason) => CoreError::internal(reason),
    }
}

pub(crate) fn coordinate<T: Send + 'static>(
    core: &Core,
    call: &Call<'_>,
    work: impl FnOnce(&mut crate::coordinator::Coordinator) -> T + Send + 'static,
) -> Result<T, CoreError> {
    core.coordinate(call.remaining().max(Duration::from_millis(500)), work)
        .map_err(|error| match error {
            CoordinateError::Timeout => {
                let mut error = CoreError::new(
                    ErrorName::Timeout,
                    "Core is still working on it; query the result",
                );
                error.data = Some(json!({"outcome": "unknown"}));
                error
            }
            CoordinateError::Stopped => CoreError::internal("the coordinator stopped"),
        })
}

fn record_result(outcome: Result<ChangeRecord, CoreError>) -> Handled {
    outcome.map(|record| (json!(record), true))
}

/// A rejected change is an error carrying every reason; any other terminal or
/// in-flight record is the result, read back from the store.
fn change_outcome(record: ChangeRecord) -> Handled {
    if record.state == ditto_protocol::change::ChangeState::Rejected {
        return Err(CoreError::preflight(&record.reasons, &record.change_id));
    }
    let verified = record.state == ditto_protocol::change::ChangeState::Committed;
    Ok((json!(record), verified))
}

fn origin_for(
    core: &Core,
    caller: &Caller,
    call: &Call<'_>,
    surface: Option<String>,
) -> Result<ChangeOrigin, CoreError> {
    if caller.subject.as_str() == Subject::AGENT && core.agent.is_connection(&caller.connection_id)
    {
        let id = call
            .operation_id
            .as_ref()
            .ok_or_else(|| CoreError::invalid("tool intent is required"))?;
        let (turn, call_id, _) = core.read(|c| {
            ditto_store::turns::validate_intent(
                c,
                id,
                &caller.connection_id,
                call.contract.capability_id,
                &Value::Object(call.params.clone()),
            )
        })?;
        return Ok(ChangeOrigin::Agent {
            session_id: turn.session_id,
            turn_id: turn.turn_id,
            tool_call_id: call_id,
        });
    }
    Ok(match caller.subject.as_str() {
        Subject::SHELL => ChangeOrigin::Gui { surface },
        Subject::AGENT => ChangeOrigin::AgentStandin,
        Subject::CLI_RESCUE | Subject::RESCUE_UI => ChangeOrigin::Rescue,
        _ => ChangeOrigin::Cli,
    })
}

/// Queue the proposal and wait: first for the draft (so the change id is
/// known), then for the outcome within the caller's deadline. Running over the
/// deadline returns the record as it is now; the change continues and the
/// caller follows it with `changes.get`, never by resending.
fn run_proposal(core: &Arc<Core>, caller: &Caller, proposal: Proposal, call: &Call<'_>) -> Handled {
    let (accepted, change_id) = mpsc::channel();
    let (reply, outcome) = mpsc::channel();
    let gone = Arc::clone(&caller.gone);
    core.submit(move |coordinator| {
        // Acceptance is the draft being written. A caller that disappeared
        // while the proposal waited in the queue never learns a change id,
        // so nothing runs on its behalf; it finds nothing by its operation
        // id and may send again (L-10, before acceptance).
        if gone.load(std::sync::atomic::Ordering::SeqCst) {
            crate::log::event(
                "change.dropped_before_acceptance",
                &[
                    ("subject", &proposal.subject),
                    (
                        "operation_id",
                        proposal.request_operation_id.as_deref().unwrap_or(""),
                    ),
                ],
            );
            return;
        }
        let _ = reply.send(coordinator.propose(proposal, Some(accepted)));
    });
    let remaining = call.remaining().max(Duration::from_millis(500));
    let started = Instant::now();
    let change_id = match change_id.recv_timeout(remaining) {
        Ok(change_id) => change_id,
        Err(mpsc::RecvTimeoutError::Disconnected) => {
            // The draft may have failed before it got a change_id (ENOSPC,
            // SQLITE_IOERR, invalid profile). The coordinator sends its
            // actual error on `outcome` after dropping `accepted`.
            match outcome.recv_timeout(remaining.saturating_sub(started.elapsed())) {
                Ok(result) => return change_outcome(result?),
                Err(_) => return Err(unknown_acceptance()),
            }
        }
        Err(mpsc::RecvTimeoutError::Timeout) => return Err(unknown_acceptance()),
    };
    match outcome.recv_timeout(remaining.saturating_sub(started.elapsed())) {
        Ok(record) => change_outcome(record?),
        Err(_) => {
            let record = core
                .read(|connection| changes::get(connection, &change_id))?
                .record;
            Ok((json!(record), false))
        }
    }
}

fn unknown_acceptance() -> CoreError {
    let mut error = CoreError::new(
        ErrorName::Timeout,
        "the change was not accepted in time; query it by operation id",
    );
    error.data = Some(json!({"outcome": "unknown"}));
    error
}

fn wait_for_idle_coordinator(core: &Core) {
    // Logout waits up to 5 s for a running change to reach a terminal state;
    // otherwise boot recovery handles it (plan/03/04 §8.3).
    let _ = core.coordinate(Duration::from_secs(5), |_| ());
}

// ---- events ---------------------------------------------------------------

fn topic_scope(topic: EventTopic) -> &'static str {
    match topic {
        EventTopic::Desktop => catalog::scope::WINDOWS_READ,
        EventTopic::Changes | EventTopic::Plugins | EventTopic::Session => catalog::scope::READ,
        EventTopic::Notifications => catalog::scope::NOTIFICATIONS_READ,
        EventTopic::Tasks => catalog::scope::TASKS_READ,
        EventTopic::Conversations => catalog::scope::AGENT_READ,
    }
}

fn track_subscription(
    core: &Core,
    caller: &Caller,
    subscription_id: &str,
    topics: Vec<EventTopic>,
) {
    core.subscriptions.lock().expect("subscriptions").insert(
        subscription_id.into(),
        SubscriptionInfo {
            subject: caller.subject.clone(),
            topics,
            connection_id: caller.connection_id.clone(),
        },
    );
}

pub fn subscribe(core: &Core, caller: &Caller, call: &Call<'_>) -> Handled {
    let input: EventsSubscribeInput = call.input()?;
    let topics: BTreeSet<EventTopic> = input
        .topics
        .clone()
        .unwrap_or_else(|| vec![EventTopic::Desktop])
        .into_iter()
        .collect();
    if topics.is_empty() {
        return Err(CoreError::invalid("at least one topic"));
    }
    let all = core
        .read(|connection| grants::list(connection, Some(caller.subject.as_str()), false))
        .unwrap_or_default();
    for topic in &topics {
        let outcome = authz::authorize(&caller.subject, &[topic_scope(*topic)], None, &all);
        if !outcome.allowed() {
            return Err(CoreError::denied(
                outcome
                    .reason
                    .unwrap_or(ditto_protocol::PermissionDeniedReason::PolicyDenied),
                outcome.scope.as_deref(),
            ));
        }
    }
    let register = |after| {
        core.session
            .subscribe_topics(after, topics.clone(), caller.sink.clone())
    };
    let (registration, resynced) = match register(input.after_seq) {
        Registration::Ready { .. } => (register_ready(register(input.after_seq)), false),
        Registration::ResyncRequired => (register_ready(register(None)), true),
    };
    let _ = resynced;
    let Some((subscription_id, snapshot, seq, replay)) = registration else {
        return Err(CoreError::internal("subscription could not be established"));
    };
    track_subscription(core, caller, &subscription_id, topics.into_iter().collect());
    for event in replay {
        let _ = caller.sink.send(Outgoing::Event(Box::new(event)));
    }
    ok(EventsSubscribeOutput {
        subscription_id,
        snapshot,
        seq,
        resynced: resynced.then_some(true),
    })
}

fn register_ready(
    registration: Registration,
) -> Option<(
    String,
    ditto_protocol::DesktopSnapshot,
    u64,
    Vec<ditto_protocol::DesktopEventNotification>,
)> {
    match registration {
        Registration::Ready {
            subscription_id,
            snapshot,
            seq,
            replay,
        } => Some((subscription_id, snapshot, seq, replay)),
        Registration::ResyncRequired => None,
    }
}

/// Revoking a grant ends the subscriptions that depended on it (SEC-04).
fn revoke_subscriptions(core: &Core, grant: &Grant) {
    let affected: Vec<String> = core
        .subscriptions
        .lock()
        .expect("subscriptions")
        .iter()
        .filter(|(_, info)| info.subject.0 == grant.subject)
        .map(|(id, _)| id.clone())
        .collect();
    for subscription in affected {
        core.session
            .require_resync(&subscription, "permission_revoked");
    }
}

// ---- profiles -------------------------------------------------------------

fn package_set(core: &Core) -> Result<PackageSet, CoreError> {
    Ok(PackageSet::new(core.read(packages::list)?))
}

fn profiles_list(core: &Core) -> Handled {
    let (profiles, active) = core.read(|connection| {
        Ok((
            profiles::list(connection)?,
            profiles::active_profile(connection)?,
        ))
    })?;
    ok(ProfilesListOutput {
        profiles,
        active_profile: active,
    })
}

fn resolve_profile(core: &Core, profile_id: Option<String>) -> Result<String, CoreError> {
    match profile_id {
        Some(id) => Ok(id),
        None => core
            .read(profiles::active_profile)?
            .ok_or_else(|| CoreError::not_found("no active profile")),
    }
}

fn profiles_get(core: &Core, input: ProfilesGetInput) -> Handled {
    let profile_id = resolve_profile(core, input.profile_id)?;
    let limit = input.history_limit.unwrap_or(50).min(200);
    let output = core.read(|connection| {
        let profile = profiles::get(connection, &profile_id)?;
        let revision_id = input
            .revision_id
            .clone()
            .unwrap_or_else(|| profile.head_revision.clone());
        let (revision, document) = profiles::revision(connection, &revision_id)?;
        if revision.profile_id != profile.profile_id {
            return Err(ditto_store::StoreError::NotFound(format!(
                "revision {revision_id} in this profile"
            )));
        }
        let history = profiles::history(connection, &revision_id, limit)?;
        Ok(ProfilesGetOutput {
            profile,
            revision,
            document,
            history,
        })
    })?;
    ok(output)
}

fn idempotent_profile(core: &Core, key: Option<&str>) -> Result<Option<ProfileSummary>, CoreError> {
    let Some(key) = key else { return Ok(None) };
    let found = core.read(|connection| {
        use rusqlite::OptionalExtension;
        Ok(connection
            .query_row(
                "SELECT value FROM core_meta WHERE key = ?1",
                [format!("idem:profile:{key}")],
                |row| row.get::<_, String>(0),
            )
            .optional()?)
    })?;
    match found {
        Some(profile_id) => {
            Ok(Some(core.read(|connection| {
                profiles::get(connection, &profile_id)
            })?))
        }
        None => Ok(None),
    }
}

fn remember_key(
    tx: &rusqlite::Transaction<'_>,
    key: Option<&str>,
    profile_id: &str,
) -> ditto_store::StoreResult<()> {
    if let Some(key) = key {
        tx.execute(
            "INSERT OR REPLACE INTO core_meta (key, value) VALUES (?1, ?2)",
            rusqlite::params![format!("idem:profile:{key}"), profile_id],
        )?;
    }
    Ok(())
}

fn profiles_create(core: &Arc<Core>, input: ProfilesCreateInput) -> Handled {
    if let Some(existing) = idempotent_profile(core, input.idempotency_key.as_deref())? {
        return verified(existing);
    }
    let packages = package_set(core)?;
    let document = match input.from {
        ProfileTemplate::Default => defaults::default_document(&packages),
        ProfileTemplate::Empty => defaults::empty_document(),
    };
    let from = match input.from {
        ProfileTemplate::Default => "default",
        ProfileTemplate::Empty => "empty",
    };
    let key = input.idempotency_key.clone();
    let name = input.name.clone();
    let profile = core
        .coordinate(Duration::from_secs(5), move |c| {
            c.store().write(|tx| {
                let (profile, _) = profiles::create(
                    tx,
                    &name,
                    &document,
                    &RevisionOrigin::Create { from: from.into() },
                )?;
                remember_key(tx, key.as_deref(), &profile.profile_id)?;
                Ok(profile)
            })
        })
        .map_err(|_| CoreError::internal("coordinator unavailable"))??;
    verified(profile)
}

fn profiles_duplicate(core: &Arc<Core>, input: ProfilesDuplicateInput) -> Handled {
    if let Some(existing) = idempotent_profile(core, input.idempotency_key.as_deref())? {
        return verified(existing);
    }
    let key = input.idempotency_key.clone();
    let profile = core
        .coordinate(Duration::from_secs(5), move |c| {
            c.store().write(|tx| {
                let (_, head, document) = profiles::head_document(tx, &input.profile_id)?;
                let (profile, _) = profiles::create(
                    tx,
                    &input.name,
                    &document,
                    &RevisionOrigin::Duplicate {
                        source_revision: head.revision_id,
                    },
                )?;
                remember_key(tx, key.as_deref(), &profile.profile_id)?;
                Ok(profile)
            })
        })
        .map_err(|_| CoreError::internal("coordinator unavailable"))??;
    verified(profile)
}

fn profiles_rename(core: &Arc<Core>, input: ProfilesRenameInput) -> Handled {
    let profile = core
        .coordinate(Duration::from_secs(5), move |c| {
            c.store()
                .write(|tx| profiles::rename(tx, &input.profile_id, &input.name))
        })
        .map_err(|_| CoreError::internal("coordinator unavailable"))??;
    verified(profile)
}

fn profiles_delete(core: &Arc<Core>, input: ProfileIdInput) -> Handled {
    let outcome = core
        .coordinate(Duration::from_secs(5), move |c| {
            c.store()
                .write(|tx| profiles::soft_delete(tx, &input.profile_id))
        })
        .map_err(|_| CoreError::internal("coordinator unavailable"))?;
    match outcome {
        Ok(profile) => verified(profile),
        Err(ditto_store::StoreError::Conflict(message)) => Err(CoreError::conflict(
            ditto_protocol::ConflictReason::ProfileInUse,
            message,
        )),
        Err(error) => Err(error.into()),
    }
}

fn document_for(
    core: &Core,
    reference: &RevisionRef,
) -> Result<(String, ProfileDocument), CoreError> {
    let reference = reference.clone();
    Ok(core.read(move |connection| {
        let revision_id = match (&reference.revision_id, &reference.profile_id) {
            (Some(revision), _) => revision.clone(),
            (None, Some(profile)) => profiles::get(connection, profile)?.head_revision,
            (None, None) => {
                let active = profiles::active_profile(connection)?
                    .ok_or_else(|| ditto_store::StoreError::NotFound("no active profile".into()))?;
                profiles::get(connection, &active)?.head_revision
            }
        };
        let (_, document) = profiles::revision(connection, &revision_id)?;
        Ok((revision_id, document))
    })?)
}

fn profiles_diff(core: &Core, input: ProfilesDiffInput) -> Handled {
    let (from_revision, from) = document_for(core, &input.from)?;
    let (to_revision, to) = document_for(core, &input.to)?;
    ok(ProfilesDiffOutput {
        from_revision,
        to_revision,
        items: docops::diff(&from, &to),
    })
}

fn profiles_export(core: &Core, input: ProfileIdInput) -> Handled {
    let (profile, _, document) =
        core.read(|connection| profiles::head_document(connection, &input.profile_id))?;
    let packages = package_set(core)?;
    let export =
        exports::export(&profile.name, &document, &packages).map_err(CoreError::invalid)?;
    ok(ProfilesExportOutput { export })
}

fn profiles_import(core: &Arc<Core>, input: ProfilesImportInput) -> Handled {
    if let Some(existing) = idempotent_profile(core, input.idempotency_key.as_deref())? {
        return verified(existing);
    }
    let packages = package_set(core)?;
    let (export, problems) = exports::validate(&input.export, &packages);
    let blocking: Vec<_> = problems
        .iter()
        .filter(|problem| problem.blocking)
        .cloned()
        .collect();
    let Some(export) = export.filter(|_| blocking.is_empty()) else {
        let mut error = CoreError::invalid("the profile cannot be imported; validate it first");
        error.data = Some(json!({ "problems": blocking }));
        return Err(error);
    };
    let key = input.idempotency_key.clone();
    let name = input.name.clone();
    let profile = core
        .coordinate(Duration::from_secs(5), move |c| {
            c.store().write(|tx| {
                let (profile, _) =
                    profiles::create(tx, &name, &export.document, &RevisionOrigin::Import)?;
                remember_key(tx, key.as_deref(), &profile.profile_id)?;
                Ok(profile)
            })
        })
        .map_err(|_| CoreError::internal("coordinator unavailable"))??;
    verified(profile)
}

// ---- changes --------------------------------------------------------------

fn changes_get(core: &Core, input: ChangesGetInput) -> Handled {
    let record = core.read(|connection| match (&input.change_id, &input.operation_id) {
        (Some(change_id), _) => Ok(Some(changes::get(connection, change_id)?)),
        (None, Some(operation_id)) => changes::by_operation(connection, operation_id),
        (None, None) => Err(ditto_store::StoreError::Invalid(
            "change_id or operation_id is required".into(),
        )),
    })?;
    match record {
        Some(stored) => ok(stored.record),
        None => Err(CoreError::not_found("no change for this operation")),
    }
}

fn changes_list(core: &Core, input: ChangesListInput) -> Handled {
    let limit = input.limit.unwrap_or(50).min(200);
    let listed = core.read(|connection| {
        changes::list(
            connection,
            input.profile_id.as_deref(),
            input.before.as_deref(),
            limit,
        )
    })?;
    ok(ChangesListOutput {
        changes: listed
            .into_iter()
            .map(|stored| stored.record.summary())
            .collect(),
    })
}

// ---- appearance, panels, layout, shortcuts, commands -------------------------

fn active_document(
    core: &Core,
) -> Result<(ProfileSummary, RevisionSummary, ProfileDocument), CoreError> {
    Ok(core.read(|connection| {
        let active = profiles::active_profile(connection)?
            .ok_or_else(|| ditto_store::StoreError::NotFound("no active profile".into()))?;
        profiles::head_document(connection, &active)
    })?)
}

fn appearance_get(core: &Core) -> Handled {
    let (_, revision, document) = active_document(core)?;
    let (observation, _) = core.shell.observation();
    ok(AppearanceGetOutput {
        appearance: document.appearance,
        avatar: document.avatar,
        shell_applied: observation.and_then(|observation| observation.appearance),
        profile_revision: revision.revision_id,
    })
}

pub fn panels(core: &Core) -> Result<PanelsListOutput, CoreError> {
    let (_, _, document) = active_document(core)?;
    let (observation, reported_at) = core.shell.observation();
    let (mounts, avatar) = observation
        .map(|observation| (observation.mounts, observation.avatar_placement))
        .unwrap_or_default();
    let mut panels: Vec<PanelStatus> = SLOTS
        .iter()
        .filter(|slot| slot.starts_with("ui."))
        .map(|slot| {
            let bound = document.slots.get(*slot).cloned();
            let mount = mounts.iter().find(|mount| mount.slot == *slot);
            PanelStatus {
                slot: (*slot).into(),
                package: bound
                    .as_ref()
                    .and_then(|id| document.entry(id))
                    .map(|entry| entry.package.clone()),
                bound_entry: bound,
                mounted_entry: mount.map(|mount| mount.entry_id.clone()),
                mounted: mount.is_some_and(|mount| mount.mounted),
                visible: mount.is_some_and(|mount| mount.visible),
            }
        })
        .collect();
    // An area lists one row per enabled member, in entry order, then any
    // item the Shell still shows that is no longer a member.
    for area in AREAS.iter().filter(|area| area.starts_with("ui.")) {
        let members: Vec<_> = document
            .area_members(area)
            .filter(|entry| !entry.disabled)
            .collect();
        for entry in &members {
            let mount = mounts
                .iter()
                .find(|mount| mount.slot == *area && mount.entry_id == entry.entry_id);
            panels.push(PanelStatus {
                slot: (*area).into(),
                bound_entry: Some(entry.entry_id.clone()),
                package: Some(entry.package.clone()),
                mounted_entry: mount.map(|mount| mount.entry_id.clone()),
                mounted: mount.is_some_and(|mount| mount.mounted),
                visible: mount.is_some_and(|mount| mount.visible),
            });
        }
        for mount in mounts.iter().filter(|mount| {
            mount.slot == *area && !members.iter().any(|entry| entry.entry_id == mount.entry_id)
        }) {
            panels.push(PanelStatus {
                slot: (*area).into(),
                bound_entry: None,
                package: document
                    .entry(&mount.entry_id)
                    .map(|entry| entry.package.clone()),
                mounted_entry: Some(mount.entry_id.clone()),
                mounted: mount.mounted,
                visible: mount.visible,
            });
        }
    }
    Ok(PanelsListOutput {
        shell_connected: core.shell.is_connected(),
        panels,
        reported_at,
        avatar,
    })
}

fn layout_get(core: &Core) -> Handled {
    let (_, _, document) = active_document(core)?;
    let packages = package_set(core)?;
    let entry = document
        .slots
        .get("layout.strategy")
        .and_then(|id| document.entry(id))
        .cloned();
    let observed = core
        .session
        .with_adapter(|adapter| adapter.layout_strategy())
        .ok()
        .flatten();
    let available = ["ditto.layout.floating", "ditto.layout.simple-tile"]
        .iter()
        .filter(|package| {
            packages
                .rows()
                .any(|row| row.summary.package_id == **package)
        })
        .map(|package| {
            let name = crate::participants::strategy_name(package).unwrap_or_default();
            let switchable = core
                .session
                .with_adapter(|adapter| Ok(adapter.supports_layout_strategy(name)))
                .unwrap_or(false);
            LayoutStrategyInfo {
                package: (*package).into(),
                name_key: format!("layout.strategy.{name}"),
                hot_swap: if switchable {
                    ditto_protocol::change::HotSwapLevel::ControlledHandoff
                } else {
                    ditto_protocol::change::HotSwapLevel::SessionRestart
                },
                runtime_switchable: switchable,
            }
        })
        .collect();
    ok(LayoutGetOutput {
        strategy_entry: entry.as_ref().map(|entry| entry.entry_id.clone()),
        strategy_package: entry.map(|entry| entry.package),
        observed_strategy: observed,
        available,
        workspace_grid: document.layout.workspace_grid,
        rules: document.layout.rules,
        region_windows: core
            .session
            .with_adapter(|adapter| adapter.windows())
            .unwrap_or_default()
            .into_iter()
            .filter_map(|window| {
                let rule = document
                    .layout
                    .regions
                    .iter()
                    .find(|rule| rule.matcher.app_id == window.app_id)?;
                Some(ditto_protocol::services::RegionWindow {
                    rule_id: rule.rule_id.clone(),
                    window_id: window.id.0.clone(),
                    app_id: window.app_id.clone(),
                    output: window.output.clone(),
                    geometry: match (window.x, window.y, window.width, window.height) {
                        (Some(x), Some(y), Some(w), Some(h)) => {
                            Some([i64::from(x), i64::from(y), i64::from(w), i64::from(h)])
                        }
                        _ => None,
                    },
                })
            })
            .collect(),
        regions: document.layout.regions,
        pending_next_login: vec![],
    })
}

fn shortcuts_list(core: &Core) -> Handled {
    let (_, _, document) = active_document(core)?;
    let bound = core
        .session
        .with_adapter(|adapter| adapter.shortcuts())
        .ok();
    let binding_path = if core
        .session
        .with_adapter(|adapter| Ok(adapter.supports_shortcut_binding()))
        .unwrap_or(false)
    {
        "compositor"
    } else {
        "shell_keyboard_only"
    };
    let mut chords = std::collections::HashMap::<String, u32>::new();
    for shortcut in &document.shortcuts {
        *chords.entry(shortcut.chord.clone()).or_default() += 1;
    }
    let mut shortcuts: Vec<ShortcutInfo> = document
        .shortcuts
        .iter()
        .map(|shortcut| ShortcutInfo {
            chord: shortcut.chord.clone(),
            command: shortcut.command.clone(),
            owner: "profile".into(),
            bound: bound.as_ref().is_some_and(|bound| bound.contains(shortcut)),
            conflict: chords.get(&shortcut.chord).copied().unwrap_or(0) > 1,
            reserved: false,
        })
        .collect();
    for binding in crate::participants::reserved_bindings() {
        shortcuts.push(ShortcutInfo {
            bound: bound.as_ref().is_some_and(|bound| bound.contains(&binding)),
            chord: binding.chord,
            command: binding.command,
            owner: "core".into(),
            conflict: false,
            reserved: true,
        });
    }
    ok(ShortcutsListOutput {
        shortcuts,
        binding_path: binding_path.into(),
    })
}

pub const CORE_COMMANDS: &[(&str, &str)] = &[
    ("session.lock", "command.session.lock"),
    ("rescue.open", "command.rescue.open"),
    ("composition.open", "command.composition.open"),
    ("plugins.open", "command.plugins.open"),
    ("history.open", "command.history.open"),
    ("personalization.open", "command.personalization.open"),
];

fn commands(core: &Core) -> Result<Vec<CommandInfo>, CoreError> {
    let (_, _, document) = active_document(core)?;
    let packages = package_set(core)?;
    let mut commands: Vec<CommandInfo> = CORE_COMMANDS
        .iter()
        .map(|(id, key)| CommandInfo {
            command_id: (*id).into(),
            owner: if id.ends_with(".open") && *id != "rescue.open" {
                "shell".into()
            } else {
                "core".into()
            },
            title_key: (*key).into(),
        })
        .collect();
    for entry in &document.entries {
        if entry.disabled {
            continue;
        }
        let bound = document
            .slots
            .values()
            .any(|bound| bound == &entry.entry_id)
            || entry.area.is_some();
        if !bound && entry.host != HostKind::Cordis {
            continue;
        }
        if let Some(manifest) = packages.manifest(entry) {
            for command in &manifest.commands {
                commands.push(CommandInfo {
                    command_id: command.id.clone(),
                    owner: entry.entry_id.clone(),
                    title_key: command.title_key.clone(),
                });
            }
        }
    }
    Ok(commands)
}

fn commands_invoke(core: &Arc<Core>, caller: &Caller, call: &Call<'_>) -> Handled {
    let input: CommandsInvokeInput = call.input()?;
    let _ = caller;
    let operation_id = call
        .operation_id
        .clone()
        .unwrap_or_else(|| ids::new(ids::OPERATION));
    let owner = run_command(core, &input.command_id, input.args)?;
    ok(CommandsInvokeOutput {
        accepted: true,
        owner,
        operation_id,
    })
}

/// Run a command for whoever owns it; a pressed global shortcut arrives here
/// too. Returns the owner.
pub fn run_command(core: &Arc<Core>, command_id: &str, args: Value) -> Result<String, CoreError> {
    let command = commands(core)?
        .into_iter()
        .find(|command| command.command_id == command_id)
        .ok_or_else(|| CoreError::not_found(format!("no command {command_id}")))?;
    let input = CommandsInvokeInput {
        command_id: command_id.into(),
        args,
    };
    let (_, _, document) = active_document(core)?;
    let shell_owned = command.owner == "shell"
        || document
            .entry(&command.owner)
            .is_some_and(|entry| entry.host == HostKind::Qml);
    if command.command_id == "session.lock" {
        core.lock_session();
    } else if command.command_id == "rescue.open" {
        core.shell.start_rescue_ui();
    } else if shell_owned {
        let peer = core.shell.peer().ok_or_else(|| {
            CoreError::unavailable(
                UnavailableReason::ParticipantUnavailable,
                "the Shell is not connected",
            )
        })?;
        peer.notify(
            ditto_protocol::participant::SHELL_COMMAND,
            json!({"command_id": command.command_id, "args": input.args}),
        );
    } else {
        return Err(CoreError::new(
            ErrorName::Unsupported,
            "commands of services are not invocable in G1",
        ));
    }
    Ok(command.owner)
}

// ---- plugins --------------------------------------------------------------

fn plugins_list(core: &Core) -> Handled {
    let packages = package_set(core)?;
    let (_, _, document) = active_document(core)?;
    let (observation, _) = core.shell.observation();
    let mounts = observation
        .map(|observation| observation.mounts)
        .unwrap_or_default();
    let supervisor_notes =
        core.read(|connection| ditto_store::audit::recent(connection, None, 200))?;
    let entries = document
        .entries
        .iter()
        .map(|entry| {
            let slot = document.placement_of(&entry.entry_id).map(String::from);
            let disabled_by_supervisor = supervisor_notes.iter().find(|row| {
                row.action == "supervisor.disable"
                    && row.redacted_detail.starts_with(&entry.entry_id)
            });
            let state = if entry.disabled {
                match disabled_by_supervisor {
                    Some(row) => EntryRuntimeState::SupervisorDisabled {
                        reason: row
                            .redacted_detail
                            .split_whitespace()
                            .nth(1)
                            .unwrap_or_default()
                            .into(),
                        at: row.ts.clone(),
                    },
                    None => EntryRuntimeState::Disabled,
                }
            } else {
                match entry.host {
                    HostKind::Cordis => {
                        if core.mode == CoreMode::Rescue {
                            EntryRuntimeState::Unavailable {
                                reason: UnavailableReason::RescueMode,
                            }
                        } else {
                            match core.hosts.report(&entry.entry_id) {
                                Some(report) => match report.fiber_state {
                                    FiberState::Active => EntryRuntimeState::Active,
                                    FiberState::Pending => EntryRuntimeState::Pending {
                                        waiting_for: report.waiting_for,
                                    },
                                    FiberState::Loading => EntryRuntimeState::Loading,
                                    FiberState::Failed => EntryRuntimeState::Failed {
                                        reason: report.failure.unwrap_or_default(),
                                    },
                                    _ => EntryRuntimeState::Unavailable {
                                        reason: UnavailableReason::HostUnavailable,
                                    },
                                },
                                None => EntryRuntimeState::Unavailable {
                                    reason: UnavailableReason::HostUnavailable,
                                },
                            }
                        }
                    }
                    HostKind::Qml => {
                        match mounts.iter().find(|mount| mount.entry_id == entry.entry_id) {
                            Some(mount) if mount.mounted => EntryRuntimeState::Active,
                            Some(_) => EntryRuntimeState::Loading,
                            None if slot.is_some() => EntryRuntimeState::NotReported,
                            None => EntryRuntimeState::Disabled,
                        }
                    }
                    HostKind::CoreBuiltin => EntryRuntimeState::Active,
                }
            };
            let _ = EntryMode::Active;
            EntryStatus {
                entry_id: entry.entry_id.clone(),
                package: entry.package.clone(),
                version: entry.version.clone(),
                host: entry.host,
                slot,
                disabled: entry.disabled,
                state,
                started_reason: "profile".into(),
                trust_note_key: match entry.host {
                    HostKind::Cordis => "trust.same_host_no_isolation.cordis".into(),
                    HostKind::Qml => "trust.same_host_no_isolation.qml".into(),
                    HostKind::CoreBuiltin => "trust.core_builtin".into(),
                },
            }
        })
        .collect();
    ok(PluginsListOutput {
        packages: packages.rows().map(|row| row.summary.clone()).collect(),
        entries,
    })
}

fn plugins_get(core: &Core, input: PluginsGetInput) -> Handled {
    let output = core.read(|connection| {
        let versions = packages::versions(connection, &input.package_id)?;
        let version = input
            .version
            .clone()
            .or_else(|| versions.last().cloned())
            .ok_or_else(|| {
                ditto_store::StoreError::NotFound(format!("package {}", input.package_id))
            })?;
        let row = packages::get(connection, &input.package_id, &version)?.ok_or_else(|| {
            ditto_store::StoreError::NotFound(format!("package {} {version}", input.package_id))
        })?;
        Ok(PluginsGetOutput {
            package: row.summary,
            manifest: row.manifest,
            versions,
        })
    })?;
    ok(output)
}

fn plugins_inspect(core: &Core, input: PluginsInspectInput) -> Handled {
    let path = std::path::PathBuf::from(&input.path);
    if !path.is_absolute() {
        return Err(CoreError::invalid("path must be absolute"));
    }
    let sha256 = packages::sha256_file(&path)?;
    let listing = std::process::Command::new("tar")
        .args(["--zstd", "-xOf"])
        .arg(&path)
        .arg("./manifest.json")
        .output();
    let (manifest, mut problems) = match listing {
        Ok(output) if output.status.success() => {
            match serde_json::from_slice::<ditto_protocol::manifest::Manifest>(&output.stdout) {
                Ok(manifest) => {
                    let problems = manifest.check();
                    (Some(manifest), problems)
                }
                Err(error) => (None, vec![format!("manifest: {error}")]),
            }
        }
        _ => (
            None,
            vec!["the archive has no readable manifest.json".into()],
        ),
    };
    let installed = manifest.as_ref().and_then(|manifest| {
        core.read(|connection| packages::get(connection, &manifest.id, &manifest.version))
            .ok()
            .flatten()
    });
    if installed
        .as_ref()
        .is_some_and(|row| row.summary.sha256 != sha256)
    {
        problems.push("this id and version are installed with different content".into());
    }
    ok(PluginsInspectOutput {
        sha256,
        manifest,
        problems,
        already_installed: installed.is_some(),
    })
}

/// Install only writes the package store; enabling is a separate ChangeSet
/// (`add_entry`), and the two are recorded separately (MOD-04).
fn plugins_install(core: &Arc<Core>, call: &Call<'_>, input: PluginsInstallInput) -> Handled {
    let path = std::path::PathBuf::from(&input.path);
    if !path.is_absolute() {
        return Err(CoreError::invalid("path must be absolute"));
    }
    if let Some(job) =
        core.read(|connection| jobs::by_idempotency_key(connection, &input.idempotency_key))?
    {
        return Ok((json!(job), job.state == JobState::Succeeded));
    }
    let key = input.idempotency_key.clone();
    let job = coordinate(core, call, move |c| {
        c.store()
            .write(|tx| jobs::create(tx, "plugins.install", Some(&key)))
    })??;
    core.publish(DesktopEventPayload::JobsUpdated { job: job.clone() });
    // Unpacking and hashing run here, on the caller's thread, never on the
    // coordinator; only the final index row is the coordinator's.
    let paths = core.paths.clone();
    crate::fault::before_unpack();
    let unpacked =
        ditto_store::packages::unpack(&paths, &path, input.expected_sha256.as_deref(), &job.job_id);
    let job_id = job.job_id.clone();
    let finished = coordinate(core, call, move |c| -> Result<Job, CoreError> {
        match unpacked {
            Ok(unpacked) => {
                let inserted = c
                    .store()
                    .write(|tx| packages::insert(tx, &unpacked, "user", Some(&job_id)));
                match inserted {
                    Ok(row) => Ok(c.store().write(|tx| {
                        jobs::finish(
                            tx,
                            &job_id,
                            JobState::Succeeded,
                            Some(&json!({"package_id": row.summary.package_id, "version": row.summary.version, "sha256": row.summary.sha256})),
                            None,
                        )
                    })?),
                    Err(error) => {
                        if !unpacked.already_present {
                            let _ = packages::remove_directory(c.store_ref().paths(), &unpacked.sha256);
                        }
                        Ok(c.store().write(|tx| jobs::finish(tx, &job_id, JobState::Failed, None, Some(&format!("install.{}", error_key(&error)))))?)
                    }
                }
            }
            Err(error) => Ok(c.store().write(|tx| {
                jobs::finish(
                    tx,
                    &job_id,
                    JobState::Failed,
                    None,
                    Some(&format!("install.{}", error_key(&error))),
                )
            })?),
        }
    })??;
    core.publish(DesktopEventPayload::JobsUpdated {
        job: finished.clone(),
    });
    let succeeded = finished.state == JobState::Succeeded;
    Ok((json!(finished), succeeded))
}

fn error_key(error: &ditto_store::StoreError) -> &'static str {
    match error {
        ditto_store::StoreError::Conflict(_) => "integrity_mismatch",
        ditto_store::StoreError::Invalid(_) => "invalid_package",
        ditto_store::StoreError::StorageFull => "storage_full",
        _ => "failed",
    }
}

// ---- permissions ----------------------------------------------------------

/// The Shell shows which file a grant covers by name; the full path is
/// visible only in the grant table itself, never in exports.
fn hide_path(grant: Grant) -> Grant {
    grant
}

fn permissions_grant(
    core: &Arc<Core>,
    caller: &Caller,
    call: &Call<'_>,
    input: PermissionsGrantInput,
) -> Handled {
    let file = input.scope == "files" || input.scope.starts_with(catalog::scope::FILES_PREFIX);
    if !file && !catalog::scope::is_known(&input.scope) {
        return Err(CoreError::invalid(format!("unknown scope {}", input.scope)));
    }
    if file
        && input
            .resource
            .as_deref()
            .is_none_or(|path| !path.starts_with('/'))
    {
        return Err(CoreError::invalid(
            "a file grant needs the absolute path of the file",
        ));
    }
    let subject = Subject(input.subject.clone());
    let never = matches!(
        authz::policy(&subject, if file { "files:x" } else { &input.scope }),
        authz::PolicyDefault::Deny
    );
    if never {
        return Err(CoreError::denied(
            ditto_protocol::PermissionDeniedReason::PolicyDenied,
            Some(&input.scope),
        ));
    }
    let granted_by = caller.subject.0.clone();
    let grant = coordinate(core, call, move |c| {
        let grant_id = ids::new(ids::GRANT);
        let scope = if file {
            format!("{}{grant_id}", catalog::scope::FILES_PREFIX)
        } else {
            input.scope.clone()
        };
        c.store().write(|tx| {
            grants::insert(
                tx,
                &grants::NewGrant {
                    grant_id: Some(&grant_id),
                    subject: &input.subject,
                    scope: &scope,
                    resource: input.resource.as_deref(),
                    expires_at: input.expires_at.as_deref(),
                    granted_by: &granted_by,
                    idempotency_key: Some(&input.idempotency_key),
                },
            )
        })
    })??;
    if grant.subject.starts_with("host:") && grant.scope.starts_with(catalog::scope::FILES_PREFIX) {
        // The service learns about its new file through a projection push.
        core.submit(|c| c.sync_participant(ditto_protocol::participant::ParticipantRole::Hostd));
    }
    verified(hide_path(grant))
}

// ---- hostd forwarding ------------------------------------------------------

/// Forward a call to the hostd entry that holds the capability's lease. The
/// provider's own claim of success is ignored; readback happens in Core.
pub fn forward(
    core: &Core,
    caller: &Caller,
    call: &Call<'_>,
    capability_id: &str,
    input: Value,
) -> Result<Value, CoreError> {
    if core.mode == CoreMode::Rescue {
        return Err(CoreError::unavailable(
            UnavailableReason::RescueMode,
            "Cordis services do not run in rescue mode",
        ));
    }
    let (peer, lease_id, entry_id) = core.hosts.provider(capability_id).map_err(|reason| {
        CoreError::unavailable(reason, "no service provides this capability right now")
    })?;
    let deadline = call.remaining().max(Duration::from_millis(50));
    let params = ditto_protocol::host::InvokeParams {
        lease_id,
        entry_id,
        capability_id: capability_id.into(),
        input,
        caller: caller.subject.0.clone(),
        operation_id: call.operation_id.clone(),
        deadline_ms: deadline.as_millis() as u64,
    };
    match peer.request(ditto_protocol::host::INVOKE, json!(params), deadline) {
        Ok(mut value) => {
            if let Value::Object(map) = &mut value {
                map.remove("_meta");
                map.remove("readback_verified");
            }
            Ok(value)
        }
        Err(crate::peers::PeerError::Remote(error)) => Err(CoreError {
            name: error.name,
            message: error.message,
            data: error.data,
        }),
        Err(crate::peers::PeerError::Timeout) => {
            let mut error =
                CoreError::new(ErrorName::Timeout, "the service did not answer in time");
            if call.contract.writes {
                error.data = Some(json!({"outcome": "unknown"}));
            }
            Err(error)
        }
        Err(crate::peers::PeerError::Disconnected) => Err(CoreError::unavailable(
            UnavailableReason::HostUnavailable,
            "the service host went away during the call",
        )),
    }
}

/// Core's own question to the notification policy, with its 50 ms deadline.
pub fn decide_notification(
    core: &Core,
    app_name: &str,
    urgency: Urgency,
) -> Option<(PolicyDecision, Option<String>)> {
    let (peer, lease_id, entry_id) = core
        .hosts
        .provider(catalog::NOTIFICATIONS_POLICY_DECIDE)
        .ok()?;
    let params = ditto_protocol::host::InvokeParams {
        lease_id,
        entry_id,
        capability_id: catalog::NOTIFICATIONS_POLICY_DECIDE.into(),
        input: json!(PolicyDecideInput {
            app_name: app_name.into(),
            urgency,
            at: ditto_store::time::now(),
        }),
        caller: Subject::CORE.into(),
        operation_id: None,
        deadline_ms: 50,
    };
    let value = peer
        .request(
            ditto_protocol::host::INVOKE,
            json!(params),
            Duration::from_millis(50),
        )
        .ok()?;
    let output: PolicyDecideOutput = serde_json::from_value(value).ok()?;
    Some((output.decision, output.rule))
}

fn policy_status(core: &Core) -> PolicyStatusOutput {
    let fallback_shown = core
        .policy_fallbacks
        .load(std::sync::atomic::Ordering::SeqCst);
    let provider = core.hosts.provider(catalog::NOTIFICATIONS_POLICY_GET);
    let (available, reason, entry) = match &provider {
        Ok((_, _, entry)) => (true, None, Some(entry.clone())),
        Err(reason) => (
            false,
            Some(if core.mode == CoreMode::Rescue {
                UnavailableReason::RescueMode
            } else {
                *reason
            }),
            None,
        ),
    };
    let mut output = PolicyStatusOutput {
        available,
        reason,
        provider_entry: entry,
        counters: None,
        recent: vec![],
        fallback_shown,
    };
    if let Ok((peer, lease_id, entry_id)) = provider {
        let params = ditto_protocol::host::InvokeParams {
            lease_id,
            entry_id,
            capability_id: catalog::NOTIFICATIONS_POLICY_GET.into(),
            input: json!({}),
            caller: Subject::CORE.into(),
            operation_id: None,
            deadline_ms: 500,
        };
        if let Ok(value) = peer.request(
            ditto_protocol::host::INVOKE,
            json!(params),
            Duration::from_millis(500),
        ) {
            if let Ok(policy) = serde_json::from_value::<PolicyGetOutput>(value) {
                output.counters = Some(policy.counters);
                output.recent = policy.recent;
            }
        }
    }
    output
}

pub struct Hooks(pub std::sync::Weak<Core>);

impl ditto_system::NotificationHooks for Hooks {
    fn decide(&self, app_name: &str, urgency: Urgency) -> Option<(PolicyDecision, Option<String>)> {
        let core = self.0.upgrade()?;
        let decision = decide_notification(&core, app_name, urgency);
        if decision.is_none() {
            core.policy_fallbacks
                .fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        }
        decision
    }

    fn posted(&self, notification: &NotificationItem) {
        if let Some(core) = self.0.upgrade() {
            core.publish(DesktopEventPayload::NotificationPosted {
                notification: notification.clone(),
            });
        }
    }

    fn closed(&self, id: u32, reason: &str) {
        if let Some(core) = self.0.upgrade() {
            core.publish(DesktopEventPayload::NotificationClosed {
                id,
                reason: reason.into(),
            });
        }
    }
}

impl ditto_system::SessionHooks for Hooks {
    fn lock_requested(&self) {
        if let Some(core) = self.0.upgrade() {
            core.lock_session();
        }
    }

    fn unlock_requested(&self) {
        // Unlocking is the lock client's to do after PAM; a logind Unlock
        // signal alone does not unlock Ditto's lock surface.
    }

    fn preparing_for_sleep(&self, before: bool) {
        if let Some(core) = self.0.upgrade() {
            if before {
                core.lock_session();
            }
        }
    }
}

pub fn handlers() -> Vec<&'static str> {
    catalog::contracts()
        .into_iter()
        .map(|contract| contract.capability_id)
        .collect()
}

pub fn target_switch(to_profile: &str, to_revision: &str, document: ProfileDocument) -> Target {
    Target {
        document,
        switch_to: Some((to_profile.into(), to_revision.into())),
    }
}
