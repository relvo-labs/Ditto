//! Diagnostics (REC-07) and rescue status. Process figures come from `/proc`
//! (read by Core), the Node heap from hostd, both listed separately; entries
//! in hostd get no memory figure of their own (RUN-08).

use std::collections::BTreeMap;

use ditto_protocol::{
    catalog::{self, Provider},
    participant::FiberState,
    profile::HostKind,
    rpc::CoreMode,
    services::*,
    UnavailableReason,
};
use ditto_store::{audit, packages, profiles};

use crate::{core::Core, error::CoreError, projection::PackageSet, router};

pub fn plugins(
    core: &Core,
    input: PluginsDiagnosticsInput,
) -> Result<PluginsDiagnosticsOutput, CoreError> {
    let (document, packages) = core.read(|connection| {
        let active = profiles::active_profile(connection)?
            .ok_or_else(|| ditto_store::StoreError::NotFound("no active profile".into()))?;
        let (_, _, document) = profiles::head_document(connection, &active)?;
        Ok((document, PackageSet::new(packages::list(connection)?)))
    })?;
    let audit = core.read(|connection| audit::recent(connection, None, 500))?;
    let mut entries = Vec::new();
    for entry in &document.entries {
        if input
            .entry_id
            .as_ref()
            .is_some_and(|wanted| wanted != &entry.entry_id)
        {
            continue;
        }
        let manifest = packages.manifest(entry);
        let dependencies = manifest
            .map(|manifest| {
                manifest
                    .requires
                    .iter()
                    .map(|item| {
                        item.package
                            .clone()
                            .or_else(|| item.service.clone())
                            .or_else(|| item.capability.clone())
                            .unwrap_or_default()
                    })
                    .collect()
            })
            .unwrap_or_default();
        let mut providers = BTreeMap::new();
        for (slot, bound) in &document.slots {
            if bound == &entry.entry_id {
                providers.insert(slot.clone(), entry.package.clone());
            }
        }
        if let Some(area) = &entry.area {
            providers.insert(area.clone(), entry.package.clone());
        }
        let report = core.hosts.report(&entry.entry_id);
        let leases = core.hosts.leases_of(&entry.entry_id);
        let last_rollback = audit
            .iter()
            .find(|row| row.action == "change.rollback")
            .map(|row| format!("{} {}", row.ts, row.decision));
        let supervisor_note = audit
            .iter()
            .find(|row| {
                row.action == "supervisor.disable"
                    && row.redacted_detail.starts_with(&entry.entry_id)
            })
            .map(|row| row.redacted_detail.clone());
        entries.push(EntryDiagnostics {
            entry_id: entry.entry_id.clone(),
            package: entry.package.clone(),
            version: entry.version.clone(),
            host: entry.host,
            dependencies,
            providers,
            fiber_state: report.as_ref().map(|report| report.fiber_state),
            waiting_for: report
                .as_ref()
                .filter(|report| report.fiber_state == FiberState::Pending)
                .map(|report| report.waiting_for.clone())
                .unwrap_or_default(),
            registrations: RegistrationCounts {
                capabilities: report.as_ref().map_or(0, |report| report.capabilities),
                leases: leases.len() as u32,
                subscriptions: report.as_ref().map_or(0, |report| report.subscriptions),
                effects: report.as_ref().map_or(0, |report| report.effects),
                timers: report.as_ref().map_or(0, |report| report.timers),
            },
            last_health: report
                .as_ref()
                .map(|report| format!("{:?}", report.fiber_state).to_lowercase()),
            last_rollback,
            supervisor_note,
            shared_host_note_key: (entry.host == HostKind::Cordis)
                .then(|| "diagnostics.shared_host_no_per_plugin_memory".into()),
        });
    }
    let (observation, _) = core.shell.observation();
    Ok(PluginsDiagnosticsOutput {
        host: core.hosts.status(),
        entries,
        core: CoreCounts {
            capability_bindings: core.hosts.lease_count() as u32,
            leases: core.hosts.lease_count() as u32,
            subscriptions: core.session.subscription_count() as u32,
            shell_mounted_providers: observation
                .map(|observation| {
                    observation
                        .mounts
                        .iter()
                        .filter(|mount| mount.mounted)
                        .count() as u32
                })
                .unwrap_or(0),
        },
    })
}

pub fn rescue_status(core: &Core) -> Result<RescueStatusOutput, CoreError> {
    let (active, head, good, recovered) = core.read(|connection| {
        let active = profiles::active_profile(connection)?;
        let profile = active
            .as_ref()
            .map(|id| profiles::get(connection, id))
            .transpose()?;
        let recovered: Vec<String> = ditto_store::changes::list(connection, None, None, 50)?
            .into_iter()
            .filter(|stored| stored.record.recovered_at.is_some())
            .map(|stored| stored.record.change_id)
            .collect();
        Ok((
            active,
            profile
                .as_ref()
                .map(|profile| profile.head_revision.clone()),
            profile.and_then(|profile| profile.last_known_good),
            recovered,
        ))
    })?;
    let mut unavailable = Vec::new();
    for contract in catalog::contracts() {
        if let Provider::Hostd(_) = contract.provider {
            let resolved = router::resolve(core, &contract);
            if let catalog::Availability::DependsOnProvider {
                available: false,
                reason,
                ..
            } = resolved.availability
            {
                unavailable.push(UnavailableCapability {
                    capability_id: contract.capability_id.into(),
                    reason: reason.unwrap_or(UnavailableReason::NotBound),
                });
            }
        }
    }
    Ok(RescueStatusOutput {
        mode: core.mode,
        host: core.hosts.status(),
        shell_connected: core.shell.is_connected(),
        active_profile: active,
        head_revision: head,
        last_known_good: good,
        unavailable,
        recovered_changes: recovered,
    })
}

pub fn is_rescue(core: &Core) -> bool {
    core.mode == CoreMode::Rescue
}
