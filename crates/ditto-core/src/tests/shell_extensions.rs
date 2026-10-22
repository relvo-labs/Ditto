//! Pure preflight/projection tests: no process launch or socket prerequisites.
use super::manifest;
use crate::{
    defaults, preflight,
    projection::{self, PackageSet, Resolver},
};
use ditto_protocol::{
    change::{ChangeOrigin, PreflightCode},
    manifest::Manifest,
    participant::{PageState, PanelMount, ShellObservation},
    profile::{EntrySpec, HostKind, ProfileDocument},
    services::PackageSummary,
};
use ditto_store::{packages::PackageRow, Paths};
use serde_json::{json, Value};

fn packages() -> PackageSet {
    PackageSet::new(
        [
            ("ditto.test.background", "ui.background", None),
            (
                "ditto.test.history",
                "ui.settings_page",
                Some(("history", 30)),
            ),
            ("ditto.test.extra", "ui.settings_page", Some(("extra", 30))),
            ("ditto.test.first", "ui.settings_page", Some(("first", -1))),
            ("ditto.test.missing", "ui.settings_page", None),
            ("ditto.test.dock", "ui.dock", None),
        ]
        .into_iter()
        .map(|(id, slot, page)| {
            let extra = page
                .map(|(page_id, order)| {
                    json!({"settings_page": {
                        "page_id": page_id, "title_key": "command.history.open", "order": order
                    }})
                })
                .unwrap_or(json!({}));
            let manifest: Manifest =
                serde_json::from_value(manifest(id, "qml_provider", "qml", &[slot], extra))
                    .unwrap();
            let summary = PackageSummary {
                package_id: id.into(),
                version: "1.0.0".into(),
                sha256: "abc".into(),
                source: "builtin".into(),
                name: json!(id),
                author: "Ditto".into(),
                license: "UNLICENSED".into(),
                plugin_kind: manifest.plugin_kind,
                host_kind: manifest.host_kind,
                trust_level: manifest.trust_level,
                installed_at: "0".into(),
                referenced_by: 0,
            };
            PackageRow {
                summary,
                manifest,
                tree_sha256: "tree".into(),
                generated: None,
            }
        })
        .collect(),
    )
}
fn entry(id: &str, package: &str, area: Option<&str>) -> EntrySpec {
    EntrySpec {
        entry_id: id.into(),
        package: package.into(),
        version: "1.0.0".into(),
        host: HostKind::Qml,
        config: json!({}),
        disabled: false,
        area: area.map(str::to_string),
    }
}
fn reasons(
    base: &ProfileDocument,
    target: &ProfileDocument,
    packages: &PackageSet,
) -> Vec<(PreflightCode, Value)> {
    let paths = Paths::under(std::path::Path::new("/unused"));
    let resolver = Resolver {
        packages,
        paths: &paths,
        grants: &[],
    };
    let context = preflight::Context {
        head_revision: "head",
        base_revision: "head",
        packages,
        resolver: &resolver,
        origin: &ChangeOrigin::Cli,
        session_locked: false,
        free_bytes: None,
        node_version: None,
        verify_trees: false,
    };
    preflight::run_target(base, target.clone(), vec![], &context)
        .reasons
        .into_iter()
        .map(|r| (r.code, r.detail.get("why").cloned().unwrap_or(Value::Null)))
        .collect()
}
fn shell(
    doc: &ProfileDocument,
    packages: &PackageSet,
) -> ditto_protocol::participant::ShellProjection {
    projection::shell(
        doc,
        &Resolver {
            packages,
            paths: &Paths::under(std::path::Path::new("/unused")),
            grants: &[],
        },
    )
}

#[test]
fn settings_metadata_is_required_and_only_enabled_ids_must_be_unique() {
    let packages = packages();
    let base = defaults::default_document(&packages);
    let mut doc = base.clone();
    doc.entries
        .push(entry("a", "ditto.test.history", Some("ui.settings_page")));
    assert!(reasons(&base, &doc, &packages).is_empty());
    doc.entries
        .push(entry("b", "ditto.test.history", Some("ui.settings_page")));
    assert!(reasons(&base, &doc, &packages)
        .contains(&(PreflightCode::SchemaInvalid, json!("duplicate_page_id"))));
    doc.entries[1].disabled = true;
    assert!(reasons(&base, &doc, &packages).is_empty());
    doc.entries
        .push(entry("c", "ditto.test.missing", Some("ui.settings_page")));
    assert!(reasons(&base, &doc, &packages)
        .contains(&(PreflightCode::SchemaInvalid, json!("settings_page_missing"))));
    doc.entries.pop();
    doc.entries[0].package = "ditto.test.dock".into();
    let errors = reasons(&base, &doc, &packages);
    assert!(errors.contains(&(
        PreflightCode::SchemaInvalid,
        json!("not_a_provider_for_area")
    )));
    doc.entries[0].host = HostKind::Cordis;
    assert!(reasons(&base, &doc, &packages)
        .contains(&(PreflightCode::SchemaInvalid, json!("wrong_host"))));
}

#[test]
fn background_uses_existing_single_provider_and_host_checks() {
    let packages = packages();
    let base = defaults::default_document(&packages);
    let mut doc = base.clone();
    doc.entries.push(entry("a", "ditto.test.background", None));
    doc.slots.insert("ui.background".into(), "a".into());
    assert!(reasons(&base, &doc, &packages).is_empty());
    assert_eq!(shell(&doc, &packages).slots[0].slot, "ui.background");
    doc.entries[0].host = HostKind::Cordis;
    assert!(reasons(&base, &doc, &packages)
        .contains(&(PreflightCode::SingleProviderViolation, json!("wrong_host"))));
    doc.entries[0].host = HostKind::Qml;
    doc.entries[0].package = "ditto.test.dock".into();
    assert!(reasons(&base, &doc, &packages).contains(&(
        PreflightCode::SingleProviderViolation,
        json!("not_a_provider_for_slot")
    )));
    doc.entries[0].package = "ditto.test.background".into();
    doc.slots.insert("ui.dock".into(), "a".into());
    assert!(reasons(&base, &doc, &packages)
        .iter()
        .any(|(code, _)| *code == PreflightCode::SingleProviderViolation));
}

#[test]
fn settings_projection_sorts_metadata_and_legacy_profile_is_unchanged() {
    let packages = packages();
    let base: ProfileDocument = serde_json::from_value(json!({
        "schema_version": 1, "entries": [{"entry_id":"dock", "package":"ditto.test.dock", "version":"1.0.0", "host":"qml", "config":{}, "disabled":false}],
        "slots":{"ui.dock":"dock"}, "appearance":defaults::appearance(),
        "avatar":ditto_protocol::profile::AvatarSettings::default(),
        "layout":{"workspace_grid":[3,3],"rules":[]}, "shortcuts":[]
    })).unwrap();
    let wire = serde_json::to_value(&base).unwrap();
    assert!(reasons(&base, &base, &packages).is_empty());
    let projected = shell(&base, &packages);
    assert_eq!(
        serde_json::to_value(&projected).unwrap(),
        json!({
            "appearance":base.appearance,"avatar":base.avatar,"shortcuts":[],
            "slots":[{"slot":"ui.dock","entry_id":"dock","package":"ditto.test.dock","version":"1.0.0",
                "qml_url":"file:///unused/data/packages/sha256/abc/qml/Provider.qml","config":{}}]
        })
    );
    assert_eq!(serde_json::to_value(&base).unwrap(), wire);
    let mut doc = base.clone();
    for (id, package) in [
        ("z", "ditto.test.history"),
        ("a", "ditto.test.extra"),
        ("x", "ditto.test.first"),
    ] {
        doc.entries
            .push(entry(id, package, Some("ui.settings_page")));
    }
    let slots = shell(&doc, &packages).slots;
    assert_eq!(
        slots
            .iter()
            .skip(1)
            .map(|s| s.settings_page.as_ref().unwrap().page_id.as_str())
            .collect::<Vec<_>>(),
        ["first", "extra", "history"]
    );
    doc.entries.reverse();
    assert_eq!(shell(&doc, &packages).slots, slots);
}

#[test]
fn new_mounts_require_identity_legacy_mounts_check_it_when_present_and_open_is_optional() {
    let packages = packages();
    for (slot, package, area) in [
        ("ui.background", "ditto.test.background", None),
        (
            "ui.settings_page",
            "ditto.test.history",
            Some("ui.settings_page"),
        ),
        ("ui.dock", "ditto.test.dock", None),
    ] {
        let mut doc = defaults::default_document(&packages);
        doc.entries.push(entry("a", package, area));
        if area.is_none() {
            doc.slots.insert(slot.into(), "a".into());
        }
        let target = shell(&doc, &packages);
        let mut seen = ShellObservation {
            mounts: vec![PanelMount {
                slot: slot.into(),
                entry_id: "a".into(),
                mounted: true,
                visible: true,
                package: None,
                version: None,
                page_state: None,
                artifact_id: None,
            }],
            appearance: Some(doc.appearance),
            avatar: Some(doc.avatar),
            avatar_placement: None,
            approval_responder: false,
        };
        let ok = |seen: &ShellObservation| projection::check_shell(&target, seen, None)[0].ok;
        assert_eq!(ok(&seen), slot == "ui.dock");
        seen.mounts[0].package = Some(package.into());
        assert_eq!(ok(&seen), slot == "ui.dock");
        seen.mounts[0].version = Some("1.0.0".into());
        assert!(ok(&seen));
        for state in [None, Some(PageState::Registered), Some(PageState::Open)] {
            seen.mounts[0].page_state = state;
            assert!(ok(&seen));
        }
        seen.mounts[0].version = Some("0.9.0".into());
        assert!(!ok(&seen));
        seen.mounts[0].version = Some("1.0.0".into());
        seen.mounts[0].package = Some("ditto.wrong".into());
        assert!(!ok(&seen));
        seen.mounts[0].package = Some(package.into());
        seen.mounts[0].visible = false;
        assert!(!ok(&seen));
        seen.mounts[0].visible = true;
        seen.mounts[0].mounted = false;
        assert!(!ok(&seen));
    }
}

#[test]
fn official_extensions_are_not_adopted_by_any_default_document() {
    let mut rows: Vec<_> = packages().rows().cloned().collect();
    for (source, official) in [
        ("ditto.test.history", "ditto.settings.history"),
        ("ditto.test.background", "ditto.background.default"),
    ] {
        let mut row = rows
            .iter()
            .find(|row| row.summary.package_id == source)
            .unwrap()
            .clone();
        row.summary.package_id = official.into();
        row.manifest.id = official.into();
        rows.push(row);
    }
    for (_, document) in defaults::builtin_documents(&PackageSet::new(rows)) {
        assert!(!document.slots.contains_key("ui.background"));
        assert_eq!(document.area_members("ui.settings_page").count(), 0);
        assert!(document
            .entries
            .iter()
            .all(|entry| entry.package != "ditto.settings.history"
                && entry.package != "ditto.background.default"));
    }
}

#[test]
fn settings_metadata_is_projected_only_for_settings_page_bindings() {
    let mut rows: Vec<_> = packages().rows().cloned().collect();
    let metadata = rows
        .iter()
        .find(|row| row.summary.package_id == "ditto.test.history")
        .unwrap()
        .manifest
        .settings_page
        .clone();
    for row in &mut rows {
        row.manifest.settings_page = metadata.clone();
    }
    let packages = PackageSet::new(rows);
    let mut doc = defaults::default_document(&packages);
    for (slot, package, area) in [
        ("ui.background", "ditto.test.background", None),
        ("ui.dock", "ditto.test.dock", None),
        (
            "ui.settings_page",
            "ditto.test.history",
            Some("ui.settings_page"),
        ),
    ] {
        doc.entries.push(entry(slot, package, area));
        if area.is_none() {
            doc.slots.insert(slot.into(), slot.into());
        }
    }
    let projected = shell(&doc, &packages);
    assert_eq!(projected.slots.len(), 3);
    for binding in projected.slots {
        assert_eq!(
            binding.settings_page,
            if binding.slot == "ui.settings_page" {
                metadata.clone()
            } else {
                None
            }
        );
    }
}
