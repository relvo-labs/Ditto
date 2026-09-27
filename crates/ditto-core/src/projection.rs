//! From one Profile document to what each participant must run, and from
//! what a participant reports back to per-item readback verdicts. Core never
//! takes a participant's word for success: it compares the observation with
//! the projection it asked for.

use std::collections::{BTreeMap, HashMap};

use ditto_protocol::{
    catalog::{self, Provider},
    change::HotSwapLevel,
    manifest::Manifest,
    participant::{
        CompositorObservation, CompositorProjection, EntryMode, FiberState, HostEntryProjection,
        HostObservation, HostProjection, ParticipantRole, Projection, ShellObservation,
        ShellProjection, ShellSlotBinding,
    },
    profile::{EntrySpec, HostKind, ProfileDocument},
    services::Grant,
};
use ditto_store::{packages::PackageRow, Paths};

use crate::participants::strategy_name;

/// Installed packages keyed by `(id, version)`.
#[derive(Clone, Default)]
pub struct PackageSet {
    rows: HashMap<(String, String), PackageRow>,
}

impl PackageSet {
    pub fn new(rows: Vec<PackageRow>) -> Self {
        Self {
            rows: rows
                .into_iter()
                .map(|row| {
                    (
                        (row.summary.package_id.clone(), row.summary.version.clone()),
                        row,
                    )
                })
                .collect(),
        }
    }

    pub fn get(&self, package: &str, version: &str) -> Option<&PackageRow> {
        self.rows.get(&(package.to_string(), version.to_string()))
    }

    pub fn manifest(&self, entry: &EntrySpec) -> Option<&Manifest> {
        self.get(&entry.package, &entry.version)
            .map(|row| &row.manifest)
    }

    pub fn rows(&self) -> impl Iterator<Item = &PackageRow> {
        self.rows.values()
    }
}

pub fn slot_role(slot: &str) -> Option<ParticipantRole> {
    if slot.starts_with("ui.") {
        Some(ParticipantRole::Shell)
    } else if slot.starts_with("svc.") {
        Some(ParticipantRole::Hostd)
    } else if slot == "layout.strategy" {
        Some(ParticipantRole::Compositor)
    } else {
        None
    }
}

pub fn expected_host(slot: &str) -> Option<HostKind> {
    match slot_role(slot)? {
        ParticipantRole::Shell => Some(HostKind::Qml),
        ParticipantRole::Hostd => Some(HostKind::Cordis),
        ParticipantRole::Compositor => Some(HostKind::CoreBuiltin),
    }
}

pub struct Resolver<'a> {
    pub packages: &'a PackageSet,
    pub paths: &'a Paths,
    pub grants: &'a [Grant],
}

impl Resolver<'_> {
    fn package_dir(&self, entry: &EntrySpec) -> Option<std::path::PathBuf> {
        self.packages
            .get(&entry.package, &entry.version)
            .map(|row| self.paths.package_dir(&row.summary.sha256))
    }
}

pub fn shell(document: &ProfileDocument, resolver: &Resolver<'_>) -> ShellProjection {
    let mut slots = Vec::new();
    for (slot, entry_id) in &document.slots {
        if slot_role(slot) != Some(ParticipantRole::Shell) {
            continue;
        }
        let Some(entry) = document.entry(entry_id) else {
            continue;
        };
        if entry.disabled || entry.host != HostKind::Qml {
            continue;
        }
        let (Some(manifest), Some(directory)) = (
            resolver.packages.manifest(entry),
            resolver.package_dir(entry),
        ) else {
            continue;
        };
        let Some(qml_entry) = &manifest.qml_entry else {
            continue;
        };
        slots.push(ShellSlotBinding {
            slot: slot.clone(),
            entry_id: entry.entry_id.clone(),
            package: entry.package.clone(),
            version: entry.version.clone(),
            qml_url: format!("file://{}", directory.join(qml_entry).display()),
            config: entry.config.clone(),
        });
    }
    ShellProjection {
        appearance: document.appearance.clone(),
        avatar: document.avatar.clone(),
        slots,
        shortcuts: document.shortcuts.clone(),
    }
}

pub fn host(document: &ProfileDocument, resolver: &Resolver<'_>) -> HostProjection {
    let mut entries = Vec::new();
    for entry in &document.entries {
        if entry.host != HostKind::Cordis || entry.disabled {
            continue;
        }
        let (Some(manifest), Some(directory)) = (
            resolver.packages.manifest(entry),
            resolver.package_dir(entry),
        ) else {
            continue;
        };
        let Some(module) = &manifest.entry else {
            continue;
        };
        let subject = format!("host:{}", entry.entry_id);
        let file_grants: BTreeMap<String, String> = resolver
            .grants
            .iter()
            .filter(|grant| {
                grant.subject == subject
                    && grant.scope.starts_with(catalog::scope::FILES_PREFIX)
                    && ditto_store::grants::is_effective(
                        grant,
                        ditto_store::time::unix_millis_now(),
                    )
            })
            .filter_map(|grant| {
                grant
                    .resource
                    .clone()
                    .map(|path| (grant.grant_id.clone(), path))
            })
            .collect();
        entries.push(HostEntryProjection {
            entry_id: entry.entry_id.clone(),
            package: entry.package.clone(),
            version: entry.version.clone(),
            module_path: directory.join(module).display().to_string(),
            data_dir: resolver
                .paths
                .plugin_data(&entry.package)
                .display()
                .to_string(),
            config: entry.config.clone(),
            disabled: false,
            provides: manifest.provided_capabilities().map(String::from).collect(),
            hot_swap: manifest.hot_swap,
            health_timeout_ms: manifest.health.timeout_ms,
            cleanup_timeout_ms: manifest.cleanup.timeout_ms,
            file_grants,
        });
    }
    HostProjection { entries }
}

pub fn compositor(document: &ProfileDocument) -> CompositorProjection {
    let strategy = document
        .slots
        .get("layout.strategy")
        .and_then(|id| document.entry(id))
        .filter(|entry| !entry.disabled)
        .map(|entry| entry.package.clone());
    CompositorProjection {
        strategy,
        layout: document.layout.clone(),
        shortcuts: document.shortcuts.clone(),
    }
}

pub fn projection(
    role: ParticipantRole,
    document: &ProfileDocument,
    resolver: &Resolver<'_>,
) -> Projection {
    match role {
        ParticipantRole::Shell => Projection::Shell(shell(document, resolver)),
        ParticipantRole::Hostd => Projection::Hostd(host(document, resolver)),
        ParticipantRole::Compositor => Projection::Compositor(compositor(document)),
    }
}

/// Participants whose projection differs between the two documents: only
/// they take part in the change.
pub fn touched(
    base: &ProfileDocument,
    target: &ProfileDocument,
    resolver: &Resolver<'_>,
) -> Vec<ParticipantRole> {
    [
        ParticipantRole::Shell,
        ParticipantRole::Hostd,
        ParticipantRole::Compositor,
    ]
    .into_iter()
    .filter(|role| projection(*role, base, resolver) != projection(*role, target, resolver))
    .collect()
}

/// The hot-swap level the ops imply, raised to what touched manifests declare.
pub fn hot_swap_level(
    base: &ProfileDocument,
    target: &ProfileDocument,
    packages: &PackageSet,
) -> HotSwapLevel {
    let mut level = HotSwapLevel::Instant;
    let raise = |level: &mut HotSwapLevel, to: HotSwapLevel| {
        if to > *level {
            *level = to;
        }
    };
    if base.layout != target.layout
        || base.slots.get("layout.strategy") != target.slots.get("layout.strategy")
    {
        raise(&mut level, HotSwapLevel::ControlledHandoff);
    }
    for slot in base.slots.keys().chain(target.slots.keys()) {
        if slot.starts_with("svc.") && base.slots.get(slot) != target.slots.get(slot) {
            raise(&mut level, HotSwapLevel::ControlledHandoff);
        }
    }
    for entry_id in crate::docops::changed_entries(base, target) {
        let entry = target.entry(&entry_id).or_else(|| base.entry(&entry_id));
        let Some(entry) = entry else { continue };
        if entry.host == HostKind::Cordis {
            raise(&mut level, HotSwapLevel::ControlledHandoff);
        }
        if let Some(manifest) = packages.manifest(entry) {
            raise(&mut level, manifest.hot_swap);
        }
    }
    level
}

#[derive(Clone, Debug, PartialEq)]
pub struct Verdict {
    pub key: String,
    pub ok: bool,
    pub reason: Option<String>,
}

fn verdict(key: &str, ok: bool, reason: &str) -> Verdict {
    Verdict {
        key: key.into(),
        ok,
        reason: (!ok).then(|| reason.into()),
    }
}

pub fn check_shell(target: &ShellProjection, observed: &ShellObservation) -> Vec<Verdict> {
    let mut verdicts = Vec::new();
    for binding in &target.slots {
        let mounted = observed.mounts.iter().any(|mount| {
            mount.slot == binding.slot
                && mount.entry_id == binding.entry_id
                && mount.mounted
                && mount.visible
        });
        verdicts.push(verdict(
            &binding.slot,
            mounted,
            "the provider is not mounted and visible",
        ));
    }
    for mount in &observed.mounts {
        let wanted = target
            .slots
            .iter()
            .any(|binding| binding.slot == mount.slot);
        if !wanted && mount.mounted {
            verdicts.push(verdict(
                &mount.slot,
                false,
                "a provider is still mounted in a slot the profile left empty",
            ));
        }
    }
    verdicts.push(verdict(
        "appearance",
        observed.appearance.as_ref() == Some(&target.appearance),
        "the shell reports a different appearance",
    ));
    verdicts.push(verdict(
        "avatar",
        observed.avatar.as_ref() == Some(&target.avatar),
        "the shell reports different avatar settings",
    ));
    verdicts
}

/// `leases_of(entry_id)` lists the capabilities with a valid lease from that
/// entry, which is Core's own table, not hostd's claim.
pub fn check_host(
    target: &HostProjection,
    observed: &HostObservation,
    leases_of: &dyn Fn(&str) -> Vec<String>,
) -> Vec<Verdict> {
    let mut verdicts = Vec::new();
    for entry in &target.entries {
        let running = observed.entries.iter().any(|seen| {
            seen.entry_id == entry.entry_id
                && seen.fiber_state == FiberState::Active
                && seen.mode == EntryMode::Active
        });
        let mut ok = running;
        let mut reason = "the service is not active";
        if running {
            let leased = leases_of(&entry.entry_id);
            let static_hostd: Vec<&String> = entry
                .provides
                .iter()
                .filter(|capability| {
                    catalog::contract(capability)
                        .is_some_and(|contract| matches!(contract.provider, Provider::Hostd(_)))
                })
                .collect();
            if static_hostd
                .iter()
                .any(|capability| !leased.contains(capability))
            {
                ok = false;
                reason = "a declared capability has no valid lease";
            }
        }
        verdicts.push(verdict(&entry.entry_id, ok, reason));
    }
    for seen in &observed.entries {
        let wanted = target
            .entries
            .iter()
            .any(|entry| entry.entry_id == seen.entry_id);
        if !wanted
            && matches!(
                seen.fiber_state,
                FiberState::Active | FiberState::Loading | FiberState::Pending
            )
        {
            verdicts.push(verdict(
                &seen.entry_id,
                false,
                "a service the profile removed is still running",
            ));
        }
    }
    verdicts
}

pub fn check_compositor(
    target: &CompositorProjection,
    observed: &CompositorObservation,
    strategy_supported: bool,
    shortcuts_supported: bool,
) -> Vec<Verdict> {
    let mut verdicts = Vec::new();
    if let Some(package) = &target.strategy {
        let expected = strategy_name(package);
        verdicts.push(verdict(
            "layout",
            strategy_supported && observed.strategy.as_deref() == expected,
            "the compositor reports a different layout strategy",
        ));
    }
    if shortcuts_supported {
        let mut expected = target.shortcuts.clone();
        let mut seen = observed.shortcuts.clone();
        expected.sort_by(|a, b| a.chord.cmp(&b.chord));
        seen.sort_by(|a, b| a.chord.cmp(&b.chord));
        verdicts.push(verdict(
            "shortcuts",
            expected == seen,
            "the compositor reports different bindings",
        ));
    }
    verdicts
}
