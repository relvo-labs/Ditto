//! #161: preflight checks an entry's `config` against its manifest
//! `config_schema` whenever a change writes a new config or moves the entry to
//! another package version. Pure preflight: no store, no participant.
use super::manifest;
use crate::{
    preflight,
    projection::{PackageSet, Resolver},
};
use ditto_protocol::{
    change::{ChangeOp, ChangeOrigin, NewEntry, PreflightCode, PreflightReason},
    manifest::Manifest,
    profile::{EntrySpec, HostKind, ProfileDocument},
    services::PackageSummary,
};
use ditto_store::{packages::PackageRow, Paths};
use serde_json::{json, Value};

const PILL: &str = "ditto.test.pill";
const LOOSE: &str = "ditto.test.loose";
const PATTERNED: &str = "ditto.test.patterned";

fn row(id: &str, version: &str, config_schema: Value) -> PackageRow {
    let mut value = manifest(
        id,
        "qml_provider",
        "qml",
        &["ui.dock"],
        json!({ "config_schema": config_schema }),
    );
    value["version"] = json!(version);
    let manifest: Manifest = serde_json::from_value(value).unwrap();
    PackageRow {
        summary: PackageSummary {
            package_id: id.into(),
            version: version.into(),
            sha256: format!("sha-{id}-{version}"),
            source: "builtin".into(),
            name: json!(id),
            author: "Ditto".into(),
            license: "UNLICENSED".into(),
            plugin_kind: manifest.plugin_kind,
            host_kind: manifest.host_kind,
            trust_level: manifest.trust_level,
            installed_at: "0".into(),
            referenced_by: 0,
        },
        manifest,
        tree_sha256: "tree".into(),
        generated: None,
    }
}

fn packages() -> PackageSet {
    let pill_v1 = json!({
        "type": "object",
        "properties": {
            "position": {"type": "string", "enum": ["bottom", "left"], "default": "bottom"},
            "icon_size": {"type": "integer", "minimum": 24, "maximum": 96},
            "pinned": {"type": "array", "items": {"type": "string"}}
        },
        "additionalProperties": false
    });
    // 2.0.0 drops "left": a config valid for 1.0.0 is not valid here.
    let mut pill_v2 = pill_v1.clone();
    pill_v2["properties"]["position"]["enum"] = json!(["bottom", "right"]);
    PackageSet::new(vec![
        row(PILL, "1.0.0", pill_v1),
        row(PILL, "2.0.0", pill_v2),
        // The Rust default when a manifest leaves config_schema out.
        row(LOOSE, "1.0.0", json!({"type": "object"})),
        // `pattern` is outside the subset the SDK allows in config_schema.
        row(
            PATTERNED,
            "1.0.0",
            json!({"type": "object", "properties": {"name": {"type": "string", "pattern": "^a"}}}),
        ),
    ])
}

fn entry(id: &str, package: &str, version: &str, config: Value) -> EntrySpec {
    EntrySpec {
        entry_id: id.into(),
        package: package.into(),
        version: version.into(),
        host: HostKind::Qml,
        config,
        disabled: false,
        area: None,
    }
}

/// A Profile holding one valid entry and one stored before #161 whose config
/// the schema refuses (`ent-legacy`).
fn base() -> ProfileDocument {
    let mut document = crate::defaults::empty_document();
    document.entries = vec![
        entry("ent-pill", PILL, "1.0.0", json!({"position": "left"})),
        entry("ent-legacy", PILL, "1.0.0", json!({"position": "middle"})),
    ];
    document.slots.insert("ui.dock".into(), "ent-pill".into());
    document
}

fn with_context<T>(origin: ChangeOrigin, run: impl FnOnce(&preflight::Context<'_>) -> T) -> T {
    let packages = packages();
    let paths = Paths::under(std::path::Path::new("/unused"));
    let resolver = Resolver {
        packages: &packages,
        paths: &paths,
        grants: &[],
    };
    let context = preflight::Context {
        head_revision: "head",
        base_revision: "head",
        packages: &packages,
        resolver: &resolver,
        origin: &origin,
        session_locked: false,
        free_bytes: None,
        node_version: None,
        verify_trees: false,
    };
    run(&context)
}

fn run(ops: Vec<ChangeOp>) -> Vec<PreflightReason> {
    with_context(ChangeOrigin::Cli, |context| {
        preflight::run(&base(), &ops, context).reasons
    })
}

fn run_target(origin: ChangeOrigin, target: ProfileDocument) -> Vec<PreflightReason> {
    with_context(origin, |context| {
        preflight::run_target(&base(), target, vec![], context).reasons
    })
}

fn why(reason: &PreflightReason) -> Option<&str> {
    reason.detail.get("why").and_then(Value::as_str)
}

fn schema_reasons(reasons: &[PreflightReason]) -> Vec<&PreflightReason> {
    reasons
        .iter()
        .filter(|reason| {
            why(reason).is_some_and(|why| why.starts_with("config_schema_"))
                || why(reason) == Some("config_not_object")
        })
        .collect()
}

fn add(package: &str, version: &str, config: Value) -> ChangeOp {
    ChangeOp::AddEntry {
        entry: NewEntry {
            package: package.into(),
            version: version.into(),
            host: HostKind::Qml,
            config,
            disabled: false,
        },
        slot: None,
    }
}

fn set_config(entry_id: &str, after: Value) -> ChangeOp {
    ChangeOp::SetEntryConfig {
        entry_id: entry_id.into(),
        before: None,
        after,
    }
}

#[test]
fn add_entry_config_is_checked_against_the_manifest_schema() {
    // Every keyword the subset has, each failing once.
    let reasons = run(vec![
        add(PILL, "1.0.0", json!({"position": "left"})),
        add(
            PILL,
            "1.0.0",
            json!({"position": "top", "icon_size": 200, "pinned": ["a", 3], "colour": "red"}),
        ),
    ]);
    let found = schema_reasons(&reasons);
    assert_eq!(found.len(), 1, "{reasons:?}");
    let reason = found[0];
    assert_eq!(reason.code, PreflightCode::SchemaInvalid);
    assert_eq!(reason.op_index, Some(1), "the reason names the op");
    assert_eq!(reason.detail_key, "preflight.schema_invalid");
    assert_eq!(why(reason), Some("config_schema_violation"));
    assert_eq!(reason.detail["package"], json!(PILL));
    assert_eq!(reason.detail["version"], json!("1.0.0"));
    let violations: Vec<(&str, &str)> = reason.detail["violations"]
        .as_array()
        .unwrap()
        .iter()
        .map(|v| {
            (
                v["pointer"].as_str().unwrap(),
                v["keyword"].as_str().unwrap(),
            )
        })
        .collect();
    assert_eq!(
        violations,
        [
            ("/colour", "additionalProperties"),
            ("/icon_size", "maximum"),
            ("/pinned/1", "type"),
            ("/position", "enum"),
        ]
    );
    assert_eq!(reason.detail["pointer"], json!("/colour"), "the first one");
}

#[test]
fn set_entry_config_is_checked_and_a_valid_config_passes() {
    let refused = run(vec![set_config("ent-pill", json!({"icon_size": 12}))]);
    let found = schema_reasons(&refused);
    assert_eq!(found.len(), 1, "{refused:?}");
    assert_eq!(found[0].op_index, Some(0));
    assert_eq!(found[0].detail["pointer"], json!("/icon_size"));
    assert_eq!(found[0].detail["entry_id"], json!("ent-pill"));
    assert_eq!(
        found[0].detail["violations"][0]["keyword"],
        json!("minimum")
    );

    let accepted = run(vec![set_config(
        "ent-pill",
        json!({"position": "bottom", "icon_size": 48, "pinned": ["firefox"]}),
    )]);
    assert!(accepted.is_empty(), "{accepted:?}");
    // Fixing a legacy entry is an ordinary write.
    let fixed = run(vec![set_config("ent-legacy", json!({}))]);
    assert!(fixed.is_empty(), "{fixed:?}");
}

#[test]
fn a_config_that_is_not_an_object_is_reported_once() {
    let reasons = run(vec![set_config("ent-pill", json!("left"))]);
    let found = schema_reasons(&reasons);
    assert_eq!(found.len(), 1, "{reasons:?}");
    assert_eq!(why(found[0]), Some("config_not_object"));
}

#[test]
fn an_upgrade_whose_schema_refuses_the_kept_config_is_rejected() {
    let reasons = run(vec![ChangeOp::UpgradeEntry {
        entry_id: "ent-pill".into(),
        from_version: "1.0.0".into(),
        to_version: "2.0.0".into(),
    }]);
    let found = schema_reasons(&reasons);
    assert_eq!(found.len(), 1, "{reasons:?}");
    assert_eq!(found[0].op_index, Some(0));
    assert_eq!(why(found[0]), Some("config_schema_violation"));
    assert_eq!(found[0].detail["version"], json!("2.0.0"));
    assert_eq!(found[0].detail["pointer"], json!("/position"));
    // The same upgrade with a config the new schema accepts goes through.
    let reasons = run(vec![
        ChangeOp::UpgradeEntry {
            entry_id: "ent-pill".into(),
            from_version: "1.0.0".into(),
            to_version: "2.0.0".into(),
        },
        set_config("ent-pill", json!({"position": "right"})),
    ]);
    assert!(schema_reasons(&reasons).is_empty(), "{reasons:?}");
}

#[test]
fn stored_entries_are_not_rechecked_when_the_change_leaves_their_config_alone() {
    // ent-legacy violates the schema, but nothing here writes its config.
    let reasons = run(vec![
        ChangeOp::SetEntryDisabled {
            entry_id: "ent-legacy".into(),
            disabled: true,
        },
        ChangeOp::SetValue {
            path: "/appearance/tokens/accent".into(),
            before: None,
            after: json!("#123456"),
        },
    ]);
    assert!(reasons.is_empty(), "{reasons:?}");
}

#[test]
fn a_missing_package_keeps_its_own_reason() {
    let reasons = run(vec![add("ditto.test.absent", "1.0.0", json!({"x": 1}))]);
    assert!(
        reasons
            .iter()
            .any(|reason| reason.code == PreflightCode::PackageMissing),
        "{reasons:?}"
    );
    assert!(schema_reasons(&reasons).is_empty(), "{reasons:?}");
}

#[test]
fn the_default_open_schema_accepts_any_object() {
    let reasons = run(vec![add(
        LOOSE,
        "1.0.0",
        json!({"anything": [1, {"a": null}]}),
    )]);
    assert!(schema_reasons(&reasons).is_empty(), "{reasons:?}");
}

#[test]
fn a_schema_outside_the_sdk_subset_is_refused_not_ignored() {
    let reasons = run(vec![add(PATTERNED, "1.0.0", json!({"name": "abc"}))]);
    let found = schema_reasons(&reasons);
    assert_eq!(found.len(), 1, "{reasons:?}");
    assert_eq!(found[0].code, PreflightCode::SchemaInvalid);
    assert_eq!(why(found[0]), Some("config_schema_unsupported"));
    assert_eq!(
        found[0].detail["schema_pointer"],
        json!("/properties/name/pattern")
    );
}

#[test]
fn a_switch_checks_the_entries_it_brings_in() {
    let mut target = base();
    target
        .entries
        .push(entry("ent-other", PILL, "1.0.0", json!({"position": "up"})));
    let reasons = run_target(ChangeOrigin::Cli, target);
    let found = schema_reasons(&reasons);
    assert_eq!(found.len(), 1, "{reasons:?}");
    assert_eq!(found[0].detail["entry_id"], json!("ent-other"));
    assert_eq!(found[0].op_index, None);
}

#[test]
fn restoring_a_stored_revision_is_not_blocked_by_the_schema() {
    // Undo, timed revert and rescue go back to content Core already stored;
    // refusing them would take away the way back.
    let mut target = base();
    target.entries[0].config = json!({"position": "up"});
    for origin in [
        ChangeOrigin::Undo {
            undoes: "chg-x".into(),
        },
        ChangeOrigin::TimedRevert {
            reverts: "chg-x".into(),
        },
        ChangeOrigin::Rescue,
        ChangeOrigin::Supervisor {
            reason: "crash_loop".into(),
        },
    ] {
        let reasons = run_target(origin.clone(), target.clone());
        assert!(
            schema_reasons(&reasons).is_empty(),
            "{origin:?}: {reasons:?}"
        );
    }
}

#[test]
fn an_import_reports_a_config_the_schema_refuses_without_blocking() {
    // A secret-looking value is nulled on export; the schema wants a string,
    // so the importer is told where to fill it in again.
    let secretive = row(
        "ditto.test.secretive",
        "1.0.0",
        json!({"type": "object", "properties": {"api_token": {"type": "string"}},
               "additionalProperties": false}),
    );
    let mut rows: Vec<PackageRow> = packages().rows().cloned().collect();
    rows.push(secretive);
    let packages = PackageSet::new(rows);
    let mut document = base();
    document.entries.push(entry(
        "ent-secret",
        "ditto.test.secretive",
        "1.0.0",
        json!({"api_token": "sk-live-123"}),
    ));
    let export = crate::exports::export("匯出", &document, &packages).unwrap();
    let (imported, problems) =
        crate::exports::validate(&serde_json::to_value(&export).unwrap(), &packages);
    assert!(imported.is_some());
    assert!(problems.iter().all(|p| !p.blocking), "{problems:?}");
    let mut found: Vec<(Value, Value)> = problems
        .iter()
        .filter(|p| p.kind == ditto_protocol::profile::ImportProblemKind::SchemaInvalid)
        .map(|p| (p.detail["entry_id"].clone(), p.detail["pointer"].clone()))
        .collect();
    found.sort_by_key(|(id, _)| id.to_string());
    assert_eq!(
        found,
        [
            (json!("ent-legacy"), json!("/position")),
            (json!("ent-secret"), json!("/api_token")),
        ]
    );
    assert!(problems
        .iter()
        .filter(|p| p.kind == ditto_protocol::profile::ImportProblemKind::SchemaInvalid)
        .all(|p| p.detail["why"] == json!("config_schema_violation")
            && p.detail_key == "import.schema_invalid"));
}

/// Every manifest the repository ships or uses as a fixture, read from disk.
fn repository_manifests() -> Vec<(std::path::PathBuf, Value)> {
    fn walk(directory: &std::path::Path, recursive: bool, out: &mut Vec<std::path::PathBuf>) {
        let mut children: Vec<_> = std::fs::read_dir(directory)
            .unwrap_or_else(|e| panic!("{}: {e}", directory.display()))
            .flatten()
            .map(|child| child.path())
            .collect();
        children.sort();
        for child in children {
            if child.is_dir() {
                let name = child.file_name().unwrap().to_string_lossy();
                if name == "node_modules" || name.starts_with('.') {
                    continue;
                }
                let manifest = child.join("manifest.json");
                if manifest.is_file() {
                    out.push(manifest);
                }
                if recursive {
                    walk(&child, true, out);
                }
            }
        }
    }
    let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
    let mut paths = Vec::new();
    walk(&root.join("shell/providers"), false, &mut paths);
    walk(&root.join("packaging/builtin"), false, &mut paths);
    walk(&root.join("packages/plugins"), false, &mut paths);
    walk(&root.join("packages/plugin-fixtures"), true, &mut paths);
    paths.dedup();
    paths
        .into_iter()
        .map(|path| {
            let text = std::fs::read_to_string(&path).unwrap();
            let value =
                serde_json::from_str(&text).unwrap_or_else(|e| panic!("{}: {e}", path.display()));
            (path, value)
        })
        .collect()
}

#[test]
fn every_shipped_and_fixture_manifest_accepts_its_default_config() {
    let manifests = repository_manifests();
    let count = |part: &str| {
        manifests
            .iter()
            .filter(|(path, _)| path.to_string_lossy().contains(part))
            .count()
    };
    // The sweep found what it is meant to cover.
    assert!(count("/shell/providers/") >= 9, "{manifests:?}");
    assert!(count("/packaging/builtin/") >= 2);
    assert!(count("/packages/plugins/") >= 2);
    assert!(count("/packages/plugin-fixtures/cordis/") >= 5);
    assert!(count("/packages/plugin-fixtures/qml/") >= 5);
    let mut rows = Vec::new();
    for (path, value) in &manifests {
        let manifest: Manifest = serde_json::from_value(value.clone())
            .unwrap_or_else(|e| panic!("{}: {e}", path.display()));
        // The Rust default applies when the file leaves config_schema out.
        let config = crate::config_schema::defaults(&manifest.config_schema);
        let violations = crate::config_schema::check(&manifest.config_schema, &config)
            .unwrap_or_else(|e| panic!("{}: unsupported {e:?}", path.display()));
        assert!(violations.is_empty(), "{}: {violations:?}", path.display());
        rows.push((manifest, config));
    }
    // The same through preflight: one add_entry per package, default config.
    let ops: Vec<ChangeOp> = rows
        .iter()
        .map(|(manifest, config)| ChangeOp::AddEntry {
            entry: NewEntry {
                package: manifest.id.clone(),
                version: manifest.version.clone(),
                host: manifest.host_kind,
                config: config.clone(),
                disabled: false,
            },
            slot: None,
        })
        .collect();
    let packages = PackageSet::new(
        rows.into_iter()
            .map(|(manifest, _)| PackageRow {
                summary: PackageSummary {
                    package_id: manifest.id.clone(),
                    version: manifest.version.clone(),
                    sha256: format!("sha-{}", manifest.id),
                    source: "builtin".into(),
                    name: json!(manifest.id),
                    author: "Ditto".into(),
                    license: "UNLICENSED".into(),
                    plugin_kind: manifest.plugin_kind,
                    host_kind: manifest.host_kind,
                    trust_level: manifest.trust_level,
                    installed_at: "0".into(),
                    referenced_by: 0,
                },
                manifest,
                tree_sha256: "tree".into(),
                generated: None,
            })
            .collect(),
    );
    let paths = Paths::under(std::path::Path::new("/unused"));
    let resolver = Resolver {
        packages: &packages,
        paths: &paths,
        grants: &[],
    };
    let context = preflight::Context {
        head_revision: "head",
        base_revision: "head",
        packages: &packages,
        resolver: &resolver,
        origin: &ChangeOrigin::Cli,
        session_locked: false,
        free_bytes: None,
        node_version: None,
        verify_trees: false,
    };
    let validation = preflight::run(&crate::defaults::empty_document(), &ops, &context);
    assert_eq!(
        validation.target.entries.len(),
        manifests.len(),
        "every package was added"
    );
    // Other checks (dependencies, conflicts, unplaced providers) may object
    // to this artificial composition; the config check must not.
    let found = schema_reasons(&validation.reasons);
    assert!(found.is_empty(), "{found:?}");
}
