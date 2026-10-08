//! Deterministic preflight (plan/03/02 §6): thirteen checks, all run, every
//! failure reported. No model is consulted and no participant is asked to do
//! anything; a refused change leaves the Profile, the store and every
//! participant exactly as they were.

use std::collections::{BTreeMap, BTreeSet, HashMap};

use ditto_protocol::{
    catalog::{self, Provider},
    change::{ChangeCard, ChangeOp, ChangeOrigin, HotSwapLevel, PreflightCode, PreflightReason},
    manifest::{Manifest, TrustLevel},
    participant::ParticipantRole,
    profile::{is_area, HostKind, ProfileDocument},
    PROTOCOL_VERSION,
};
use serde_json::json;

use crate::{
    docops::{self, reason},
    projection::{self, PackageSet, Resolver},
};

/// Chords Core keeps for rescue and lock; a plugin may not declare them.
pub const RESERVED_CHORDS: &[&str] = &["Super+Escape", "Super+Shift+Escape", "Super+L"];
/// Scopes a hostd entry can never be granted; asking for them fails preflight.
const HOST_NEVER: &[&str] = &[
    catalog::scope::SESSION_POWER,
    catalog::scope::PLUGINS_MANAGE,
    catalog::scope::PERMISSIONS_MANAGE,
    catalog::scope::CORE,
    catalog::scope::RESCUE,
];
/// Service-class budget ceiling (D-06b); a manifest asking for more is refused.
pub const MAX_SERVICE_MEMORY_MIB: u32 = 64;
pub const MAX_SERVICE_CPU_PERCENT: u32 = 10;

pub struct Context<'a> {
    pub head_revision: &'a str,
    pub base_revision: &'a str,
    pub packages: &'a PackageSet,
    pub resolver: &'a Resolver<'a>,
    pub origin: &'a ChangeOrigin,
    pub session_locked: bool,
    pub free_bytes: Option<u64>,
    /// Node version hostd reported, when known.
    pub node_version: Option<&'a str>,
    /// Verify installed trees against their recorded digest (off in tests
    /// that install nothing on disk).
    pub verify_trees: bool,
}

pub struct Validation {
    pub target: ProfileDocument,
    pub ops: Vec<ChangeOp>,
    pub reasons: Vec<PreflightReason>,
    pub card: ChangeCard,
    pub level: HotSwapLevel,
    pub touched: Vec<ParticipantRole>,
}

fn origin_may_change_while_locked(origin: &ChangeOrigin) -> bool {
    matches!(
        origin,
        ChangeOrigin::Rescue | ChangeOrigin::Supervisor { .. } | ChangeOrigin::TimedRevert { .. }
    )
}

fn version_matches(range: &str, version: &str) -> bool {
    match (
        semver::VersionReq::parse(range),
        semver::Version::parse(version),
    ) {
        (Ok(range), Ok(version)) => range.matches(&version),
        _ => false,
    }
}

/// Run all thirteen checks on `ops` applied to `base`.
pub fn run(base: &ProfileDocument, ops: &[ChangeOp], context: &Context<'_>) -> Validation {
    let applied = docops::apply(base, ops);
    let target = applied.document;
    let mut reasons = applied.reasons;
    check_all(base, &target, &mut reasons, context);
    finish(base, target, applied.ops, reasons, context)
}

/// For a profile switch or a restore the target document is given whole.
pub fn run_target(
    base: &ProfileDocument,
    target: ProfileDocument,
    ops: Vec<ChangeOp>,
    context: &Context<'_>,
) -> Validation {
    let mut reasons = Vec::new();
    check_all(base, &target, &mut reasons, context);
    finish(base, target, ops, reasons, context)
}

fn finish(
    base: &ProfileDocument,
    target: ProfileDocument,
    ops: Vec<ChangeOp>,
    reasons: Vec<PreflightReason>,
    context: &Context<'_>,
) -> Validation {
    let items = docops::diff(base, &target);
    let card = docops::card(&ops, items);
    let level = projection::hot_swap_level(base, &target, context.packages);
    let touched = projection::touched(base, &target, context.resolver);
    Validation {
        target,
        ops,
        reasons,
        card,
        level,
        touched,
    }
}

fn check_all(
    base: &ProfileDocument,
    target: &ProfileDocument,
    reasons: &mut Vec<PreflightReason>,
    context: &Context<'_>,
) {
    // 1. base revision is the head (CFG-06, CHG-05)
    if context.base_revision != context.head_revision {
        reasons.push(reason(
            PreflightCode::BaseRevisionStale,
            None,
            json!({"base_revision": context.base_revision, "head_revision": context.head_revision}),
        ));
    }
    // 2. schema: the document as a whole still deserializes and ids are unique
    let mut seen = BTreeSet::new();
    for entry in &target.entries {
        if !seen.insert(&entry.entry_id) {
            reasons.push(reason(
                PreflightCode::SchemaInvalid,
                None,
                json!({"entry_id": entry.entry_id, "why": "duplicate_entry_id"}),
            ));
        }
    }
    // Region rules (D-40): stable unique ids, an application to match, a
    // rectangle inside the work area, and a bounded number of rules.
    let mut rule_ids = BTreeSet::new();
    if target.layout.regions.len() > 32 {
        reasons.push(reason(
            PreflightCode::SchemaInvalid,
            None,
            json!({"why": "too_many_region_rules", "limit": 32}),
        ));
    }
    for rule in &target.layout.regions {
        let why = if rule.rule_id.trim().is_empty() || rule.rule_id.len() > 64 {
            Some("region_rule_id_invalid")
        } else if !rule_ids.insert(&rule.rule_id) {
            Some("duplicate_region_rule_id")
        } else if rule.matcher.app_id.trim().is_empty() || rule.matcher.app_id.len() > 256 {
            Some("region_match_invalid")
        } else if !rule.region.valid() {
            Some("region_out_of_bounds")
        } else {
            None
        };
        if let Some(why) = why {
            reasons.push(reason(
                PreflightCode::SchemaInvalid,
                None,
                json!({"rule_id": rule.rule_id, "why": why}),
            ));
        }
    }
    // An area is not a slot: its members are entries that name it, so the
    // single-provider map may not hold it, and only known areas are named.
    for slot in target.slots.keys() {
        if is_area(slot) {
            reasons.push(reason(
                PreflightCode::SchemaInvalid,
                None,
                json!({"slot": slot, "why": "area_is_not_a_slot"}),
            ));
        }
    }
    for entry in &target.entries {
        let Some(area) = &entry.area else { continue };
        if !is_area(area) {
            reasons.push(reason(
                PreflightCode::SchemaInvalid,
                None,
                json!({"entry_id": entry.entry_id, "area": area, "why": "unknown_area"}),
            ));
        }
        if target.slots.values().any(|bound| bound == &entry.entry_id) {
            reasons.push(reason(
                PreflightCode::SchemaInvalid,
                None,
                json!({"entry_id": entry.entry_id, "area": area, "why": "placed_twice"}),
            ));
        }
    }
    let changed = docops::changed_entries(base, target);
    let enabled: Vec<_> = target
        .entries
        .iter()
        .filter(|entry| !entry.disabled)
        .collect();
    let mut manifests: HashMap<&str, &Manifest> = HashMap::new();
    // 3. packages installed and intact (only for what this change touches:
    // the rest was checked when it was last changed and at boot)
    for entry in &target.entries {
        match context.packages.get(&entry.package, &entry.version) {
            None => {
                if changed.contains(&entry.entry_id) || !entry.disabled {
                    reasons.push(reason(
                        PreflightCode::PackageMissing,
                        None,
                        json!({"package": entry.package, "version": entry.version}),
                    ));
                }
            }
            Some(row) => {
                manifests.insert(entry.entry_id.as_str(), &row.manifest);
                if context.verify_trees && changed.contains(&entry.entry_id) {
                    let directory = context.resolver.paths.package_dir(&row.summary.sha256);
                    let intact = ditto_store::packages::tree_digest(&directory)
                        .map(|digest| digest == row.tree_sha256)
                        .unwrap_or(false);
                    if !intact {
                        reasons.push(reason(
                            PreflightCode::IntegrityMismatch,
                            None,
                            json!({"package": entry.package, "version": entry.version}),
                        ));
                    }
                }
                if row.manifest.host_kind != entry.host {
                    reasons.push(reason(
                        PreflightCode::SchemaInvalid,
                        None,
                        json!({"package": entry.package, "why": "host_kind_mismatch"}),
                    ));
                }
            }
        }
    }
    // 4. protocol and runtime compatibility
    for entry in &enabled {
        let Some(manifest) = manifests.get(entry.entry_id.as_str()) else {
            continue;
        };
        if !version_matches(&manifest.required_protocol_version, PROTOCOL_VERSION) {
            reasons.push(reason(
                PreflightCode::ProtocolIncompatible,
                None,
                json!({"package": entry.package, "requires": manifest.required_protocol_version, "have": PROTOCOL_VERSION}),
            ));
        }
        if let (Some(range), Some(node)) = (&manifest.runtime.node, context.node_version) {
            if !version_matches(range, node) {
                reasons.push(reason(
                    PreflightCode::ProtocolIncompatible,
                    None,
                    json!({"package": entry.package, "requires_node": range, "have": node}),
                ));
            }
        }
        if !manifest.platform.is_empty()
            && !manifest
                .platform
                .iter()
                .any(|platform| platform == "linux-x86_64")
        {
            reasons.push(reason(
                PreflightCode::PreconditionFailed,
                None,
                json!({"package": entry.package, "why": "platform"}),
            ));
        }
        // G1 enables only built-in trusted packages; a manifest's claim is a
        // request the policy may refuse.
        if changed.contains(&entry.entry_id)
            && (manifest.trust_level != TrustLevel::Trusted
                || context
                    .packages
                    .get(&entry.package, &entry.version)
                    .is_some_and(|row| row.summary.source != "builtin"))
        {
            reasons.push(reason(
                PreflightCode::PreconditionFailed,
                None,
                json!({"package": entry.package, "why": "trust_policy"}),
            ));
        }
    }
    // 5.–7. dependency closure, cycles and version ranges among enabled entries
    let mut provides_service: HashMap<&str, &str> = HashMap::new();
    let mut provides_capability: HashMap<&str, Vec<&str>> = HashMap::new();
    for entry in &enabled {
        if let Some(manifest) = manifests.get(entry.entry_id.as_str()) {
            for service in manifest.provided_services() {
                provides_service.insert(service, entry.entry_id.as_str());
            }
            for capability in manifest.provided_capabilities() {
                provides_capability
                    .entry(capability)
                    .or_default()
                    .push(entry.entry_id.as_str());
            }
        }
    }
    let mut edges: BTreeMap<&str, Vec<&str>> = BTreeMap::new();
    for entry in &enabled {
        let Some(manifest) = manifests.get(entry.entry_id.as_str()) else {
            continue;
        };
        for requirement in &manifest.requires {
            if let Some(package) = &requirement.package {
                let candidates: Vec<_> = enabled
                    .iter()
                    .filter(|other| &other.package == package)
                    .collect();
                match candidates.first() {
                    None => reasons.push(reason(
                        PreflightCode::DependencyMissing,
                        None,
                        json!({"package": entry.package, "requires": package}),
                    )),
                    Some(provider) => {
                        if let Some(range) = &requirement.version {
                            if !candidates
                                .iter()
                                .any(|candidate| version_matches(range, &candidate.version))
                            {
                                reasons.push(reason(
                                    PreflightCode::VersionConflict,
                                    None,
                                    json!({"package": entry.package, "requires": package, "range": range, "have": provider.version}),
                                ));
                            }
                        }
                        edges
                            .entry(entry.entry_id.as_str())
                            .or_default()
                            .push(provider.entry_id.as_str());
                    }
                }
            }
            if let Some(service) = &requirement.service {
                match provides_service.get(service.as_str()) {
                    None => reasons.push(reason(
                        PreflightCode::DependencyMissing,
                        None,
                        json!({"package": entry.package, "service": service}),
                    )),
                    Some(provider) => edges
                        .entry(entry.entry_id.as_str())
                        .or_default()
                        .push(provider),
                }
            }
            if let Some(capability) = &requirement.capability {
                let from_core = catalog::contract(capability)
                    .is_some_and(|contract| !matches!(contract.provider, Provider::Hostd(_)));
                if !from_core && !provides_capability.contains_key(capability.as_str()) {
                    reasons.push(reason(
                        PreflightCode::DependencyMissing,
                        None,
                        json!({"package": entry.package, "capability": capability}),
                    ));
                }
            }
        }
    }
    for cycle in cycles(&edges) {
        reasons.push(reason(
            PreflightCode::DependencyCycle,
            None,
            json!({"entries": cycle}),
        ));
    }
    // 8. declared conflicts
    for entry in &enabled {
        let Some(manifest) = manifests.get(entry.entry_id.as_str()) else {
            continue;
        };
        for conflict in &manifest.conflicts {
            if enabled.iter().any(|other| &other.package == conflict) {
                reasons.push(reason(
                    PreflightCode::DeclaredConflict,
                    None,
                    json!({"package": entry.package, "conflicts_with": conflict}),
                ));
            }
        }
    }
    // 9. single provider: the bound entry can fill the slot, runs in the host
    // the slot needs, and no capability has two enabled providers
    let mut bound_twice: HashMap<&str, Vec<&str>> = HashMap::new();
    for (slot, entry_id) in &target.slots {
        bound_twice
            .entry(entry_id.as_str())
            .or_default()
            .push(slot.as_str());
        let Some(entry) = target.entry(entry_id) else {
            reasons.push(reason(
                PreflightCode::SingleProviderViolation,
                None,
                json!({"slot": slot, "why": "no_such_entry"}),
            ));
            continue;
        };
        if projection::expected_host(slot).is_some_and(|host| host != entry.host) {
            reasons.push(reason(
                PreflightCode::SingleProviderViolation,
                None,
                json!({"slot": slot, "why": "wrong_host"}),
            ));
        }
        if let Some(manifest) = manifests.get(entry.entry_id.as_str()) {
            if !manifest.slots.iter().any(|declared| declared == slot) {
                reasons.push(reason(
                    PreflightCode::SingleProviderViolation,
                    None,
                    json!({"slot": slot, "package": entry.package, "why": "not_a_provider_for_slot"}),
                ));
            }
        }
    }
    // Area members: any number, but each must be able to fill the area and
    // run in the host it needs. This is not a single-provider rule.
    for entry in &target.entries {
        let Some(area) = entry.area.as_deref().filter(|area| is_area(area)) else {
            continue;
        };
        if projection::expected_host(area).is_some_and(|host| host != entry.host) {
            reasons.push(reason(
                PreflightCode::SchemaInvalid,
                None,
                json!({"area": area, "package": entry.package, "why": "wrong_host"}),
            ));
        }
        if let Some(manifest) = manifests.get(entry.entry_id.as_str()) {
            if !manifest.slots.iter().any(|declared| declared == area) {
                reasons.push(reason(
                    PreflightCode::SchemaInvalid,
                    None,
                    json!({"area": area, "package": entry.package, "why": "not_a_provider_for_area"}),
                ));
            }
        }
    }
    for (entry_id, slots) in bound_twice {
        if slots.len() > 1 {
            reasons.push(reason(
                PreflightCode::SingleProviderViolation,
                None,
                json!({"entry_id": entry_id, "slots": slots}),
            ));
        }
    }
    for (capability, providers) in &provides_capability {
        if providers.len() > 1 && capability.starts_with("desktop.") {
            reasons.push(reason(
                PreflightCode::SingleProviderViolation,
                None,
                json!({"capability": capability, "entries": providers}),
            ));
        }
    }
    // 10. shortcuts and commands have one owner after the change (AT-04).
    // Only slot-bound, area and service entries own commands: an installed
    // but unplaced provider is not mounted, so it owns nothing.
    let mut command_owner: HashMap<&str, &str> = HashMap::new();
    let mut chord_owner: HashMap<&str, (&str, &str)> = HashMap::new();
    for shortcut in &target.shortcuts {
        if let Some((_, previous)) = chord_owner.insert(
            shortcut.chord.as_str(),
            ("profile", shortcut.command.as_str()),
        ) {
            if previous != shortcut.command {
                reasons.push(reason(
                    PreflightCode::ShortcutConflict,
                    None,
                    json!({"chord": shortcut.chord}),
                ));
            }
        }
    }
    let owning: Vec<_> = enabled
        .iter()
        .filter(|entry| {
            entry.host == HostKind::Cordis
                || entry.area.is_some()
                || target.slots.values().any(|bound| bound == &entry.entry_id)
        })
        .collect();
    for entry in owning {
        let Some(manifest) = manifests.get(entry.entry_id.as_str()) else {
            continue;
        };
        for command in &manifest.commands {
            if let Some(other) = command_owner.insert(command.id.as_str(), entry.entry_id.as_str())
            {
                reasons.push(reason(
                    PreflightCode::CommandConflict,
                    None,
                    json!({"command": command.id, "entries": [other, entry.entry_id]}),
                ));
            }
        }
        for shortcut in &manifest.shortcuts {
            if RESERVED_CHORDS.contains(&shortcut.chord.as_str()) {
                reasons.push(reason(
                    PreflightCode::ShortcutConflict,
                    None,
                    json!({"chord": shortcut.chord, "why": "reserved"}),
                ));
            }
            match chord_owner.get(shortcut.chord.as_str()) {
                Some((owner, command)) if *command != shortcut.command || *owner != "profile" => {
                    reasons.push(reason(
                        PreflightCode::ShortcutConflict,
                        None,
                        json!({"chord": shortcut.chord, "entries": [owner, entry.entry_id]}),
                    ));
                }
                _ => {
                    chord_owner.insert(
                        shortcut.chord.as_str(),
                        (entry.entry_id.as_str(), shortcut.command.as_str()),
                    );
                }
            }
        }
    }
    // 11. permissions the policy can never give a service are refused now;
    // grantable ones are requests, answered by the grant table at call time.
    for entry in &enabled {
        if !changed.contains(&entry.entry_id) || entry.host != HostKind::Cordis {
            continue;
        }
        let Some(manifest) = manifests.get(entry.entry_id.as_str()) else {
            continue;
        };
        for scope in &manifest.permissions {
            let known = catalog::scope::is_known(scope) || scope == "files:*";
            if !known || HOST_NEVER.contains(&scope.as_str()) {
                reasons.push(reason(
                    PreflightCode::PermissionRequired,
                    None,
                    json!({"package": entry.package, "scope": scope}),
                ));
            }
        }
    }
    // 12. preconditions: an unlocked session, and room to write
    if context.session_locked && !origin_may_change_while_locked(context.origin) {
        reasons.push(reason(
            PreflightCode::PreconditionFailed,
            None,
            json!({"why": "session_locked"}),
        ));
    }
    if context
        .free_bytes
        .is_some_and(|free| free < ditto_store::MIN_FREE_BYTES)
    {
        reasons.push(reason(
            PreflightCode::PreconditionFailed,
            None,
            json!({"why": "storage_low", "free_bytes": context.free_bytes}),
        ));
    }
    // 13. resource budgets are requests within policy ceilings
    for entry in &enabled {
        let Some(manifest) = manifests.get(entry.entry_id.as_str()) else {
            continue;
        };
        let budget = &manifest.resource_budget;
        if budget
            .memory_mib
            .is_some_and(|mib| mib > MAX_SERVICE_MEMORY_MIB)
            || budget
                .cpu_percent
                .is_some_and(|cpu| cpu > MAX_SERVICE_CPU_PERCENT)
        {
            reasons.push(reason(
                PreflightCode::BudgetExceeded,
                None,
                json!({"package": entry.package, "memory_mib": budget.memory_mib, "cpu_percent": budget.cpu_percent}),
            ));
        }
    }
}

/// Strongly connected components with more than one member, or a self-loop
/// (Tarjan).
fn cycles<'a>(edges: &BTreeMap<&'a str, Vec<&'a str>>) -> Vec<Vec<&'a str>> {
    struct Walk<'a, 'b> {
        edges: &'b BTreeMap<&'a str, Vec<&'a str>>,
        index: HashMap<&'a str, usize>,
        low: HashMap<&'a str, usize>,
        stack: Vec<&'a str>,
        on_stack: BTreeSet<&'a str>,
        next: usize,
        found: Vec<Vec<&'a str>>,
    }
    impl<'a> Walk<'a, '_> {
        fn visit(&mut self, node: &'a str) {
            self.index.insert(node, self.next);
            self.low.insert(node, self.next);
            self.next += 1;
            self.stack.push(node);
            self.on_stack.insert(node);
            for &next in self.edges.get(node).map(Vec::as_slice).unwrap_or(&[]) {
                if !self.index.contains_key(next) {
                    self.visit(next);
                    let low = self.low[node].min(self.low[next]);
                    self.low.insert(node, low);
                } else if self.on_stack.contains(next) {
                    let low = self.low[node].min(self.index[next]);
                    self.low.insert(node, low);
                }
            }
            if self.low[node] == self.index[node] {
                let mut component = Vec::new();
                while let Some(top) = self.stack.pop() {
                    self.on_stack.remove(top);
                    component.push(top);
                    if top == node {
                        break;
                    }
                }
                let self_loop = self
                    .edges
                    .get(node)
                    .is_some_and(|next| next.contains(&node));
                if component.len() > 1 || self_loop {
                    component.sort();
                    self.found.push(component);
                }
            }
        }
    }
    let mut walk = Walk {
        edges,
        index: HashMap::new(),
        low: HashMap::new(),
        stack: Vec::new(),
        on_stack: BTreeSet::new(),
        next: 0,
        found: Vec::new(),
    };
    for &node in edges.keys() {
        if !walk.index.contains_key(node) {
            walk.visit(node);
        }
    }
    walk.found
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tarjan_finds_cycles_and_self_loops_only() {
        let mut edges: BTreeMap<&str, Vec<&str>> = BTreeMap::new();
        edges.insert("a", vec!["b"]);
        edges.insert("b", vec!["c"]);
        edges.insert("c", vec!["a"]);
        edges.insert("d", vec!["a"]);
        edges.insert("e", vec!["e"]);
        let found = cycles(&edges);
        assert_eq!(found, vec![vec!["a", "b", "c"], vec!["e"]]);
    }
}
