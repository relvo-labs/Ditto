//! The built-in default Profile ("soft-jelly"). Only packages that are
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
