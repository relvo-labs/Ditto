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
        AvatarPlacement, CompositorObservation, CompositorProjection, EntryMode, FiberState,
        HostEntryProjection, HostObservation, HostProjection, ParticipantRole, Projection,
        ShellObservation, ShellProjection, ShellSlotBinding,
    },
    profile::{is_area, AvatarSettings, EntrySpec, HostKind, ProfileDocument, AREAS},
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

/// One binding per single-provider `ui.*` slot, then one per enabled member
/// of each area, in entry order except settings pages, sorted by metadata.
pub fn shell(document: &ProfileDocument, resolver: &Resolver<'_>) -> ShellProjection {
    let binding = |slot: &str, entry: &EntrySpec| -> Option<ShellSlotBinding> {
        if entry.disabled || entry.host != HostKind::Qml {
            return None;
        }
        let manifest = resolver.packages.manifest(entry)?;
        let directory = resolver.package_dir(entry)?;
        let qml_entry = manifest.qml_entry.as_ref()?;
        let row = resolver.packages.get(&entry.package, &entry.version)?;
        let generated = row.generated.as_ref();
        if row.summary.source == "generated"
            && !generated.is_some_and(|a| {
                ditto_store::generated::approved(a) && ditto_store::generated::integrity(a)
            })
        {
            return None;
        }
        Some(ShellSlotBinding {
            settings_page: manifest.settings_page.clone(),
            slot: slot.into(),
            entry_id: entry.entry_id.clone(),
            package: entry.package.clone(),
            version: entry.version.clone(),
            qml_url: if generated.is_some(){"ditto-generated:fixed".into()}else{format!("file://{}", directory.join(qml_entry).display())},
            config: generated.map(|a|serde_json::json!({"artifact_id":a.artifact_id,"description":a.description})).unwrap_or_else(||entry.config.clone()),
        })
    };
    let mut slots = Vec::new();
    for (slot, entry_id) in &document.slots {
        if slot_role(slot) != Some(ParticipantRole::Shell) || is_area(slot) {
            continue;
        }
        if let Some(found) = document
            .entry(entry_id)
            .and_then(|entry| binding(slot, entry))
        {
            slots.push(found);
        }
    }
    for area in AREAS {
        if slot_role(area) != Some(ParticipantRole::Shell) {
            continue;
        }
        let mut members: Vec<_> = document
            .area_members(area)
            .filter_map(|entry| binding(area, entry))
            .collect();
        if *area == "ui.settings_page" {
            members.sort_by(|a, b| {
                a.settings_page
                    .as_ref()
                    .map(|p| (p.order, &p.page_id))
                    .cmp(&b.settings_page.as_ref().map(|p| (p.order, &p.page_id)))
            });
        }
        slots.extend(members);
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

/// `connected` lists the outputs the compositor reports, when it can be
/// asked; it decides whether a named output should hold the character.
pub fn check_shell(
    target: &ShellProjection,
    observed: &ShellObservation,
    connected: Option<&[String]>,
) -> Vec<Verdict> {
    let mut verdicts = Vec::new();
    // A slot is read back by its name; an area member by its entry id, since
    // an area holds many.
    let key = |slot: &str, entry_id: &str| -> String {
        if is_area(slot) {
            entry_id.into()
        } else {
            slot.into()
        }
    };
    for binding in &target.slots {
        let mount = observed
            .mounts
            .iter()
            .find(|mount| mount.slot == binding.slot && mount.entry_id == binding.entry_id);
        let mounted = mount.is_some_and(|mount| mount.mounted && mount.visible);
        let identity_required =
            matches!(binding.slot.as_str(), "ui.background" | "ui.settings_page");
        let correct_identity = mount.is_some_and(|m| {
            m.package
                .as_ref()
                .map_or(!identity_required, |p| p == &binding.package)
                && m.version
                    .as_ref()
                    .map_or(!identity_required, |v| v == &binding.version)
        });
        let correct_artifact = binding.qml_url != "ditto-generated:fixed"
            || binding.config["artifact_id"]
                .as_str()
                .is_some_and(|wanted| {
                    mount.and_then(|mount| mount.artifact_id.as_deref()) == Some(wanted)
                });
        verdicts.push(verdict(
            &key(&binding.slot, &binding.entry_id),
            mounted && correct_artifact && correct_identity,
            if mounted && !correct_identity {
                "the mounted package or version differs from the requested binding"
            } else if mounted && !correct_artifact {
                "the mounted generated artifact differs from the requested version"
            } else {
                "the provider is not mounted and visible"
            },
        ));
    }
    for mount in &observed.mounts {
        let wanted = target.slots.iter().any(|binding| {
            binding.slot == mount.slot
                && (!is_area(&mount.slot) || binding.entry_id == mount.entry_id)
        });
        if !wanted && mount.mounted {
            verdicts.push(verdict(
                &key(&mount.slot, &mount.entry_id),
                false,
                if is_area(&mount.slot) {
                    "an item the profile removed from the area is still mounted"
                } else {
                    "a provider is still mounted in a slot the profile left empty"
                },
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
    // A Shell that reports where the character is gets that read back too;
    // one that reports no placement is judged on the settings alone.
    if let Some(placement) = &observed.avatar_placement {
        let (ok, reason) = check_avatar_placement(&target.avatar, placement, connected);
        verdicts.push(verdict("avatar_placement", ok, reason));
    }
    verdicts
}

fn check_avatar_placement(
    avatar: &AvatarSettings,
    placement: &AvatarPlacement,
    connected: Option<&[String]>,
) -> (bool, &'static str) {
    if !avatar.enabled || avatar.hidden {
        // A hidden character may still be on screen after a recall.
        return (true, "");
    }
    if !placement.visible {
        return (false, "the character is not on screen");
    }
    if placement.corner != avatar.corner {
        return (false, "the character is in a different corner");
    }
    let named_is_connected = avatar
        .output
        .as_ref()
        .map(|name| connected.map(|outputs| outputs.iter().any(|output| output == name)));
    let ok = match named_is_connected {
        None => placement.follows_primary,
        Some(Some(true)) => !placement.follows_primary && placement.output == avatar.output,
        Some(Some(false)) => placement.follows_primary,
        Some(None) => placement.follows_primary || placement.output == avatar.output,
    };
    (ok, "the character is not on the output the profile names")
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
    // Windows the commit placed by region rules: where the compositor says
    // they are, within the declared tolerance of where the rule puts them.
    for placement in &observed.regions {
        verdicts.push(verdict(
            &format!("region:{}:{}", placement.rule_id, placement.window_id),
            placement.placed(),
            "the window is not where its region rule puts it",
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

#[cfg(test)]
mod tests {
    use super::*;
    use ditto_protocol::participant::PanelMount;
    use ditto_protocol::profile::{Appearance, AvatarSettings};

    fn binding(slot: &str, entry_id: &str) -> ShellSlotBinding {
        ShellSlotBinding {
            slot: slot.into(),
            entry_id: entry_id.into(),
            settings_page: None,
            package: format!("pkg-{entry_id}"),
            version: "1.0.0".into(),
            qml_url: "file:///x.qml".into(),
            config: serde_json::json!({}),
        }
    }

    fn mount(slot: &str, entry_id: &str, visible: bool) -> PanelMount {
        PanelMount {
            slot: slot.into(),
            entry_id: entry_id.into(),
            mounted: true,
            visible,
            artifact_id: None,
            package: None,
            version: None,
            page_state: None,
        }
    }

    fn appearance() -> Appearance {
        Appearance {
            theme: "soft-jelly".into(),
            tokens: Default::default(),
            reduced_motion: false,
            reduced_transparency: false,
            low_power_style: false,
            locale: "zh-TW".into(),
        }
    }

    #[test]
    fn assistant_readback_requires_the_selected_presentation() {
        let mut avatar = AvatarSettings::default();
        let mut target = ShellProjection {
            appearance: appearance(),
            avatar: avatar.clone(),
            slots: vec![],
            shortcuts: vec![],
        };
        let observed = ShellObservation {
            mounts: vec![],
            appearance: Some(appearance()),
            avatar: Some(avatar.clone()),
            avatar_placement: None,
            approval_responder: false,
        };
        avatar.presentation = Some(ditto_protocol::profile::AvatarPresentation::Assistant);
        target.avatar = avatar.clone();
        assert!(
            !check_shell(&target, &observed, None)
                .iter()
                .find(|v| v.key == "avatar")
                .unwrap()
                .ok
        );
        let observed = ShellObservation {
            avatar: Some(avatar),
            ..observed
        };
        assert!(
            check_shell(&target, &observed, None)
                .iter()
                .find(|v| v.key == "avatar")
                .unwrap()
                .ok
        );
    }

    #[test]
    fn generated_upgrade_requires_the_actual_mounted_artifact() {
        let mut generated = binding("ui.generated_panel", "ent-generated");
        generated.qml_url = "ditto-generated:fixed".into();
        generated.config = serde_json::json!({"artifact_id":"art-new"});
        let target = ShellProjection {
            appearance: appearance(),
            avatar: AvatarSettings::default(),
            slots: vec![generated],
            shortcuts: vec![],
        };
        let mut observed = ShellObservation {
            mounts: vec![mount("ui.generated_panel", "ent-generated", true)],
            appearance: Some(appearance()),
            avatar: Some(AvatarSettings::default()),
            avatar_placement: None,
            approval_responder: false,
        };
        assert!(
            !check_shell(&target, &observed, None)[0].ok,
            "the entry id alone must not prove that a generated upgrade loaded"
        );
        observed.mounts[0].artifact_id = Some("art-old".into());
        assert!(!check_shell(&target, &observed, None)[0].ok);
        observed.mounts[0].artifact_id = Some("art-new".into());
        assert!(check_shell(&target, &observed, None)[0].ok);
    }

    #[test]
    fn several_area_members_are_read_back_one_by_one() {
        let target = ShellProjection {
            appearance: appearance(),
            avatar: AvatarSettings::default(),
            slots: vec![
                binding("ui.dock", "ent-dock"),
                binding("ui.status_item", "ent-a"),
                binding("ui.status_item", "ent-b"),
            ],
            shortcuts: vec![],
        };
        let observed = |mounts: Vec<PanelMount>| ShellObservation {
            mounts,
            appearance: Some(appearance()),
            avatar: Some(AvatarSettings::default()),
            avatar_placement: None,
            approval_responder: false,
        };
        let all = check_shell(
            &target,
            &observed(vec![
                mount("ui.dock", "ent-dock", true),
                mount("ui.status_item", "ent-a", true),
                mount("ui.status_item", "ent-b", true),
            ]),
            None,
        );
        assert!(all.iter().all(|verdict| verdict.ok), "{all:?}");
        let keys: Vec<&str> = all.iter().map(|verdict| verdict.key.as_str()).collect();
        assert_eq!(keys, ["ui.dock", "ent-a", "ent-b", "appearance", "avatar"]);

        // One member missing, one hidden, and one the profile no longer has.
        let wrong = check_shell(
            &target,
            &observed(vec![
                mount("ui.dock", "ent-dock", true),
                mount("ui.status_item", "ent-b", false),
                mount("ui.status_item", "ent-gone", true),
            ]),
            None,
        );
        let failed: Vec<&str> = wrong
            .iter()
            .filter(|verdict| !verdict.ok)
            .map(|verdict| verdict.key.as_str())
            .collect();
        assert_eq!(failed, ["ent-a", "ent-b", "ent-gone"]);
    }
}
