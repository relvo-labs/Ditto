//! Plugin manifest. A manifest is a request: trust, permissions and budgets
//! are decided by Core's policy and grants, and descriptive text grants
//! nothing. See `docs/contracts/manifest.md`.

use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::{change::HotSwapLevel, profile::HostKind};

pub const MANIFEST_VERSION: u32 = 1;

#[derive(Clone, Copy, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum PluginKind {
    Service,
    QmlProvider,
    DeclarativeBundle,
}

impl PluginKind {
    /// The only host each kind may run in.
    pub fn host(self) -> HostKind {
        match self {
            Self::Service => HostKind::Cordis,
            Self::QmlProvider => HostKind::Qml,
            Self::DeclarativeBundle => HostKind::CoreBuiltin,
        }
    }
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum TrustLevel {
    Trusted,
    Community,
    Untrusted,
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum IdlePolicy {
    Resident,
    OnDemand,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Default)]
#[serde(deny_unknown_fields)]
pub struct RuntimeRequirement {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub node: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub qt: Option<String>,
}

/// What a package provides or depends on. Exactly one field is set.
#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq, Default)]
#[serde(deny_unknown_fields)]
pub struct Item {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub capability: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub service: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub package: Option<String>,
    /// semver range, for `package` dependencies.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub version: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct CommandDecl {
    pub id: String,
    pub title_key: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct ShortcutDecl {
    pub chord: String,
    pub command: String,
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum Coalesce {
    None,
    Latest,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct EventDecl {
    pub name: String,
    pub schema: Value,
    pub coalesce: Coalesce,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct TimeoutDecl {
    pub timeout_ms: u64,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq, Default)]
#[serde(deny_unknown_fields)]
pub struct ResourceBudget {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub memory_mib: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cpu_percent: Option<u32>,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq, Default)]
#[serde(deny_unknown_fields)]
pub struct RescueDecl {
    #[serde(default)]
    pub disable_safe: bool,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct Manifest {
    pub manifest_version: u32,
    pub id: String,
    pub version: String,
    /// A string, or a `{ locale: text }` object.
    pub name: Value,
    pub author: String,
    pub license: String,
    pub source: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<Value>,
    pub plugin_kind: PluginKind,
    pub host_kind: HostKind,
    pub trust_level: TrustLevel,
    #[serde(default)]
    pub runtime: RuntimeRequirement,
    #[serde(default)]
    pub platform: Vec<String>,
    pub required_protocol_version: String,
    #[serde(default)]
    pub slots: Vec<String>,
    #[serde(default)]
    pub provides: Vec<Item>,
    #[serde(default)]
    pub requires: Vec<Item>,
    #[serde(default)]
    pub optional: Vec<Item>,
    #[serde(default)]
    pub conflicts: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub entry: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub qml_entry: Option<String>,
    #[serde(default = "open_object_schema")]
    pub config_schema: Value,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub data_schema: Option<Value>,
    #[serde(default)]
    pub commands: Vec<CommandDecl>,
    #[serde(default)]
    pub shortcuts: Vec<ShortcutDecl>,
    #[serde(default)]
    pub events: Vec<EventDecl>,
    #[serde(default)]
    pub permissions: Vec<String>,
    pub hot_swap: HotSwapLevel,
    pub health: TimeoutDecl,
    pub cleanup: TimeoutDecl,
    #[serde(default)]
    pub migrations: Vec<Value>,
    #[serde(default)]
    pub activation_events: Vec<String>,
    pub idle_policy: IdlePolicy,
    #[serde(default)]
    pub resource_budget: ResourceBudget,
    #[serde(default)]
    pub rescue: RescueDecl,
}

fn open_object_schema() -> Value {
    serde_json::json!({ "type": "object" })
}

impl Manifest {
    pub fn provided_capabilities(&self) -> impl Iterator<Item = &str> {
        self.provides
            .iter()
            .filter_map(|item| item.capability.as_deref())
    }

    pub fn provided_services(&self) -> impl Iterator<Item = &str> {
        self.provides
            .iter()
            .filter_map(|item| item.service.as_deref())
    }

    /// Structural checks that need no other package: id and version form,
    /// kind and host agreement, the entry file the host needs.
    pub fn check(&self) -> Vec<String> {
        let mut problems = Vec::new();
        if self.manifest_version != MANIFEST_VERSION {
            problems.push(format!("manifest_version must be {MANIFEST_VERSION}"));
        }
        if !valid_package_id(&self.id) {
            problems.push(format!("invalid package id {}", self.id));
        }
        if semver::Version::parse(&self.version).is_err() {
            problems.push(format!("version {} is not semver", self.version));
        }
        if semver::VersionReq::parse(&self.required_protocol_version).is_err() {
            problems.push("required_protocol_version is not a semver range".into());
        }
        if self.plugin_kind.host() != self.host_kind {
            problems.push("plugin_kind and host_kind do not match".into());
        }
        match self.host_kind {
            HostKind::Cordis if self.entry.is_none() => {
                problems.push("cordis plugin needs entry".into())
            }
            HostKind::Qml if self.qml_entry.is_none() => {
                problems.push("qml provider needs qml_entry".into())
            }
            _ => {}
        }
        for path in self.entry.iter().chain(self.qml_entry.iter()) {
            if path.starts_with('/') || path.split('/').any(|part| part == "..") {
                problems.push(format!("entry path {path} must stay inside the package"));
            }
        }
        for item in self
            .provides
            .iter()
            .chain(&self.requires)
            .chain(&self.optional)
        {
            let set = [&item.capability, &item.service, &item.package]
                .iter()
                .filter(|field| field.is_some())
                .count();
            if set != 1 {
                problems.push("each provides/requires item names exactly one thing".into());
            }
            if let Some(range) = &item.version {
                if semver::VersionReq::parse(range).is_err() {
                    problems.push(format!("version range {range} is not semver"));
                }
            }
        }
        for event in &self.events {
            if !event.schema.is_object() {
                problems.push(format!("event {} needs a schema", event.name));
            }
        }
        problems
    }
}

pub fn valid_package_id(id: &str) -> bool {
    let mut parts = id.split('.');
    let Some(first) = parts.next() else {
        return false;
    };
    let head_ok = !first.is_empty()
        && first
            .bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit());
    let rest: Vec<&str> = parts.collect();
    head_ok
        && !rest.is_empty()
        && rest.iter().all(|part| {
            !part.is_empty()
                && part
                    .bytes()
                    .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'_' || b == b'-')
        })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn manifest() -> Manifest {
        serde_json::from_value(serde_json::json!({
            "manifest_version": 1, "id": "ditto.dock.pill", "version": "1.0.0",
            "name": {"zh-TW": "膠囊 Dock", "en": "Pill dock"}, "author": "Ditto", "license": "UNLICENSED",
            "source": "builtin", "plugin_kind": "qml_provider", "host_kind": "qml",
            "trust_level": "trusted", "required_protocol_version": "^0.2",
            "slots": ["ui.dock"], "qml_entry": "qml/DockPill.qml",
            "hot_swap": "instant", "health": {"timeout_ms": 2000}, "cleanup": {"timeout_ms": 2000},
            "idle_policy": "resident"
        }))
        .unwrap()
    }

    #[test]
    fn a_consistent_manifest_has_no_problems() {
        assert!(manifest().check().is_empty(), "{:?}", manifest().check());
    }

    #[test]
    fn mismatched_kind_and_escaping_paths_are_caught() {
        let mut bad = manifest();
        bad.host_kind = HostKind::Cordis;
        bad.qml_entry = Some("../../etc/passwd".into());
        let problems = bad.check();
        assert!(problems.iter().any(|p| p.contains("do not match")));
        assert!(problems.iter().any(|p| p.contains("inside the package")));
        assert!(problems.iter().any(|p| p.contains("needs entry")));
    }

    #[test]
    fn package_ids_are_reverse_domain() {
        assert!(valid_package_id("ditto.svc.tasks"));
        assert!(valid_package_id("ditto.fixture.cpu-usage"));
        assert!(!valid_package_id("ditto"));
        assert!(!valid_package_id("Ditto.dock"));
        assert!(!valid_package_id("ditto..dock"));
    }
}
