//! The built-in Profiles ("soft-jelly"). Only packages that are
//! actually installed appear in it: a document that pins a missing package
//! would fail every later preflight.

use std::collections::BTreeMap;

use ditto_protocol::{
    ids,
    profile::{
        Appearance, AvatarSettings, EntrySpec, HostKind, LayoutIntent, ProfileDocument,
        ShortcutBinding, SCHEMA_VERSION,
    },
};
use serde_json::json;

use crate::projection::PackageSet;

pub const DEFAULT_PROFILE_NAME: &str = "預設";

/// `(slot, package, host)` of the default composition.
pub const DEFAULT_SLOTS: &[(&str, &str, HostKind)] = &[
    ("ui.panel_top", "ditto.panel.top", HostKind::Qml),
    ("ui.dock", "ditto.dock.bottom", HostKind::Qml),
    ("ui.launcher", "ditto.launcher.grid", HostKind::Qml),
    ("ui.tasks_panel", "ditto.tasks.panel", HostKind::Qml),
    (
        "ui.notifications",
        "ditto.notifications.area",
        HostKind::Qml,
    ),
    (
        "layout.strategy",
        "ditto.layout.floating",
        HostKind::CoreBuiltin,
    ),
    ("svc.tasks", "ditto.svc.tasks", HostKind::Cordis),
    (
        "svc.notification_policy",
        "ditto.svc.notification-policy",
        HostKind::Cordis,
    ),
];

pub fn appearance() -> Appearance {
    Appearance {
        theme: "soft-jelly".into(),
        tokens: [("accent".to_string(), "#b9a4ff".to_string())]
            .into_iter()
            .collect(),
        reduced_motion: false,
        reduced_transparency: false,
        low_power_style: false,
        locale: "zh-TW".into(),
    }
}

fn newest_version(packages: &PackageSet, package: &str) -> Option<String> {
    packages
        .rows()
        .filter(|row| row.summary.package_id == package)
        .filter(|row| row.summary.source == "builtin")
        .filter_map(|row| semver::Version::parse(&row.summary.version).ok())
        .max()
        .map(|version| version.to_string())
}

pub fn default_document(packages: &PackageSet) -> ProfileDocument {
    let mut entries = Vec::new();
    let mut slots = BTreeMap::new();
    for (slot, package, host) in DEFAULT_SLOTS {
        let Some(version) = newest_version(packages, package) else {
            continue;
        };
        let entry_id = ids::new(ids::ENTRY);
        entries.push(EntrySpec {
            entry_id: entry_id.clone(),
            package: (*package).into(),
            version,
            host: *host,
            config: json!({}),
            disabled: false,
            area: None,
        });
        slots.insert((*slot).to_string(), entry_id);
    }
    ProfileDocument {
        schema_version: SCHEMA_VERSION,
        entries,
        slots,
        layout: LayoutIntent {
            workspace_grid: [3, 3],
            rules: vec![],
            regions: vec![],
        },
        appearance: appearance(),
        shortcuts: vec![
            ShortcutBinding {
                chord: "Super+Space".into(),
                command: "launcher.toggle".into(),
            },
            ShortcutBinding {
                chord: "Super+A".into(),
                command: "chat.toggle".into(),
            },
        ],
        avatar: AvatarSettings::default(),
    }
}

/// First-login compositions, in activation order. Purpose-specific choices
/// are agent proposals pending owner confirmation (PRD §20.1); names are
/// display data, never inputs to routing or intent interpretation.
pub fn builtin_documents(packages: &PackageSet) -> [(&'static str, ProfileDocument); 3] {
    let default = default_document(packages);
    let mut development = default.clone();
    replace_slot(&mut development, packages, "ui.dock", "ditto.dock.pill");
    replace_slot(
        &mut development,
        packages,
        "ui.launcher",
        "ditto.launcher.search",
    );
    replace_slot(
        &mut development,
        packages,
        "layout.strategy",
        "ditto.layout.simple-tile",
    );
    if let Some(entry) = development
        .slots
        .get("ui.dock")
        .cloned()
        .and_then(|id| development.entry_mut(&id))
    {
        if entry.package == "ditto.dock.pill" {
            entry.config = json!({"position": "left"});
        }
    }
    let mut presentation = default.clone();
    if let Some(entry) = presentation
        .slots
        .get("svc.notification_policy")
        .cloned()
        .and_then(|id| presentation.entry_mut(&id))
    {
        // The installed service still lets critical notifications through.
        entry.config = json!({"rules": {"focus": {"enabled": true, "allow": []}}});
    }
    presentation.avatar.hidden = true;
    presentation.avatar.animations = false;
    [
        (DEFAULT_PROFILE_NAME, default),
        ("開發", development),
        ("簡報", presentation),
    ]
}

/// Retain the installed default when a purpose-specific alternative is absent.
/// Preserve the entry id and every unrelated field, as a normal slot edit does.
fn replace_slot(document: &mut ProfileDocument, packages: &PackageSet, slot: &str, package: &str) {
    let Some(version) = newest_version(packages, package) else {
        return;
    };
    let Some(id) = document.slots.get(slot).cloned() else {
        return;
    };
    if let Some(entry) = document.entry_mut(&id) {
        entry.package = package.into();
        entry.version = version;
        entry.config = json!({});
    }
}

pub fn empty_document() -> ProfileDocument {
    ProfileDocument {
        schema_version: SCHEMA_VERSION,
        entries: vec![],
        slots: BTreeMap::new(),
        layout: LayoutIntent {
            workspace_grid: [3, 3],
            rules: vec![],
            regions: vec![],
        },
        appearance: appearance(),
        shortcuts: vec![],
        avatar: AvatarSettings::default(),
    }
}
