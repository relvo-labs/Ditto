//! Development evidence: real built-in manifests with fixture participants.
//! Native application survival and visuals still require a VM/reference seat.

use super::*;
use ditto_protocol::profile::{ProfileDocument, RevisionOrigin};
use ditto_store::profiles;

fn shipped_harness(label: &str) -> Harness {
    let root = root(label);
    let builtin = root.join("builtin");
    std::fs::create_dir_all(&builtin).unwrap();
    for text in [
        include_str!("../../../../shell/providers/panel_top/manifest.json"),
        include_str!("../../../../shell/providers/dock_bottom/manifest.json"),
        include_str!("../../../../shell/providers/dock_pill/manifest.json"),
        include_str!("../../../../shell/providers/launcher_grid/manifest.json"),
        include_str!("../../../../shell/providers/launcher_search/manifest.json"),
        include_str!("../../../../shell/providers/tasks_panel/manifest.json"),
        include_str!("../../../../shell/providers/notifications/manifest.json"),
        include_str!("../../../../packaging/builtin/ditto.layout.floating/manifest.json"),
        include_str!("../../../../packaging/builtin/ditto.layout.simple-tile/manifest.json"),
        include_str!("../../../../packages/plugins/svc-tasks/manifest.json"),
        include_str!("../../../../packages/plugins/svc-notification-policy/manifest.json"),
    ] {
        let mut manifest: Value = serde_json::from_str(text).unwrap();
        // Use the existing peer fixture, preserving the shipped config schemas,
        // versions, commands and permissions. This does not execute QML/Node.
        if manifest.get("qml_entry").is_some() {
            manifest["qml_entry"] = json!("qml/Provider.qml");
        }
        pack(&builtin, &manifest);
    }
    let core = start_at(&root, false);
    Harness { core, root }
}

fn get(peer: &TestPeer, id: &Value) -> Value {
    peer.result(catalog::PROFILES_GET, json!({"profile_id": id}))
}

fn switch(peer: &TestPeer, id: &Value) -> ChangeRecord {
    record(&peer.result(
        catalog::CHANGES_PROPOSE,
        json!({"base_revision": head(peer), "ops": [{"op": "switch_profile", "to_profile": id}]}),
    ))
}

// Direct Store readback keeps bootstrap/upgrade evidence runnable without IPC.
fn stored_list(core: &Arc<Core>) -> Value {
    core.coordinate(Duration::from_secs(10), |co| {
        let connection = co.store_ref().connection();
        json!({"profiles": profiles::list(connection).unwrap(),
            "active_profile": profiles::active_profile(connection).unwrap()})
    })
    .unwrap()
}

fn stored_get(core: &Arc<Core>, id: &Value) -> Value {
    let id = id.as_str().unwrap().to_string();
    core.coordinate(Duration::from_secs(10), move |co| {
        let connection = co.store_ref().connection();
        let (profile, revision, document) = profiles::head_document(connection, &id).unwrap();
        let history = profiles::history(connection, &revision.revision_id, 100).unwrap();
        json!({"profile": profile, "revision": revision, "document": document, "history": history})
    })
    .unwrap()
}

#[test]
fn first_login_seeds_three_exportable_compositions_once() {
    let harness = shipped_harness("builtin-first-login");
    let listed = stored_list(&harness.core);
    let profiles = listed["profiles"].as_array().unwrap();
    assert_eq!(profiles.len(), 3);
    assert_eq!(profiles.iter().filter(|p| p["active"] == true).count(), 1);
    let mut before = Vec::new();
    for name in ["預設", "開發", "簡報"] {
        let summary = profiles.iter().find(|p| p["name"] == name).unwrap();
        let saved = stored_get(&harness.core, &summary["profile_id"]);
        assert_eq!(saved["document"]["appearance"]["theme"], "soft-jelly-light");
        assert_eq!(saved["history"].as_array().unwrap().len(), 1);
        let doc: ProfileDocument = serde_json::from_value(saved["document"].clone()).unwrap();
        let export_doc = doc.clone();
        let export_name = name.to_string();
        harness
            .core
            .coordinate(Duration::from_secs(10), move |co| {
                let packages = co.packages();
                let exported =
                    crate::exports::export(&export_name, &export_doc, &packages).unwrap();
                assert_eq!(exported.document, export_doc);
                assert_eq!(exported.packages.len(), 8);
                let (imported, problems) =
                    crate::exports::validate(&serde_json::to_value(exported).unwrap(), &packages);
                assert!(problems.is_empty(), "{problems:?}");
                assert_eq!(imported.unwrap().document, export_doc);
            })
            .unwrap();
        assert_eq!(doc.digest(), saved["revision"]["document_sha256"]);
        // D-48 shares appearance across compositions, but assistant rendering
        // is deliberately default-only; purpose-specific avatars stay legacy.
        assert_eq!(
            doc.avatar.presentation,
            if name == "預設" {
                Some(ditto_protocol::profile::AvatarPresentation::Assistant)
            } else {
                None
            }
        );
        if name == "預設" {
            assert_eq!(summary["profile_id"], listed["active_profile"]);
            assert_eq!(
                doc.avatar,
                ditto_protocol::profile::AvatarSettings {
                    presentation: Some(ditto_protocol::profile::AvatarPresentation::Assistant),
                    ..Default::default()
                }
            );
        }
        before.push((summary["profile_id"].clone(), saved));
    }
    // Re-enter the actual boot path; neither additions nor revisions are made.
    harness
        .core
        .coordinate(Duration::from_secs(10), |co| co.boot(None))
        .unwrap();
    let after = stored_list(&harness.core);
    assert_eq!(after["active_profile"], listed["active_profile"]);
    assert_eq!(after["profiles"].as_array().unwrap().len(), 3);
    for (id, saved) in before {
        let actual = stored_get(&harness.core, &id);
        assert_eq!(actual["document"], saved["document"]);
        assert_eq!(
            actual["profile"]["head_revision"],
            saved["profile"]["head_revision"]
        );
        assert_eq!(
            actual["profile"]["updated_at"],
            saved["profile"]["updated_at"]
        );
        assert_eq!(actual["history"].as_array().unwrap().len(), 1);
    }
}

#[test]
fn failed_bootstrap_leaves_no_partial_profiles_or_active_pointer() {
    let root = root("builtin-atomic-bootstrap");
    let paths = Paths::under(&root.join("store"));
    {
        let lock = ditto_store::WriterLock::acquire(&paths.lock()).unwrap();
        let (mut store, _) = ditto_store::Store::open_writer(&paths, &lock).unwrap();
        store
            .write(|tx| {
                tx.execute_batch(
                    "CREATE TRIGGER refuse_second_profile BEFORE INSERT ON profiles
                WHEN NEW.name = '開發' BEGIN SELECT RAISE(ABORT, 'test bootstrap failure'); END;",
                )?;
                Ok(())
            })
            .unwrap();
    }
    let core = start_at(&root, false);
    let harness = Harness { core, root };
    let listed = stored_list(&harness.core);
    assert!(listed["profiles"].as_array().unwrap().is_empty());
    assert!(listed["active_profile"].is_null());
    harness
        .core
        .coordinate(Duration::from_secs(10), |co| {
            assert_eq!(
                co.store_ref()
                    .connection()
                    .query_row("SELECT COUNT(*) FROM revisions", [], |r| r.get::<_, u32>(0))
                    .unwrap(),
                0
            );
            co.store()
                .write(|tx| {
                    tx.execute_batch("DROP TRIGGER refuse_second_profile")?;
                    Ok(())
                })
                .unwrap();
            co.boot(None);
        })
        .unwrap();
    assert_eq!(
        stored_list(&harness.core)["profiles"]
            .as_array()
            .unwrap()
            .len(),
        3
    );
}

#[test]
fn upgrade_preserves_legacy_profiles_with_or_without_an_active_id() {
    for (with_active, names) in [
        (true, vec!["我的桌面"]),
        (false, vec!["我的桌面"]),
        (true, vec!["我的桌面", "開發", "簡報"]),
        (false, vec!["我的桌面", "開發", "簡報"]),
    ] {
        let root = root("builtin-upgrade");
        let paths = Paths::under(&root.join("store"));
        let mut saved = Vec::new();
        {
            let lock = ditto_store::WriterLock::acquire(&paths.lock()).unwrap();
            let (mut store, _) = ditto_store::Store::open_writer(&paths, &lock).unwrap();
            store
                .write(|tx| {
                    for name in &names {
                        let document = plain_document("#123456");
                        let (profile, revision) = profiles::create(
                            tx,
                            name,
                            &document,
                            &RevisionOrigin::Create {
                                from: "empty".into(),
                            },
                        )?;
                        if with_active && saved.is_empty() {
                            profiles::set_active_profile(tx, &profile.profile_id)?;
                        }
                        saved.push((profile, revision, document));
                    }
                    Ok(())
                })
                .unwrap();
        }
        let core = start_at(&root, false);
        let harness = Harness { core, root };
        let listed = stored_list(&harness.core);
        assert_eq!(listed["profiles"].as_array().unwrap().len(), saved.len());
        assert_eq!(listed["active_profile"], saved[0].0.profile_id);
        for (profile, revision, document) in saved {
            let actual = stored_get(&harness.core, &json!(profile.profile_id));
            assert_eq!(actual["profile"]["name"], profile.name);
            assert_eq!(actual["profile"]["head_revision"], revision.revision_id);
            assert_eq!(actual["profile"]["updated_at"], profile.updated_at);
            assert_eq!(actual["revision"]["document_sha256"], document.digest());
            assert_eq!(actual["document"], document.to_value());
            assert_eq!(actual["history"].as_array().unwrap().len(), 1);
        }
    }
}

#[test]
fn builtin_switches_read_back_without_rewriting_documents_and_can_be_undone() {
    let harness = shipped_harness("builtin-switch");
    let state = Arc::new(Mutex::new(ShellState::default()));
    let _shell = fake_shell(&harness.core, Arc::clone(&state));
    let host = Arc::new(Mutex::new(HostState::default()));
    let _host = fake_host(&harness.core, Arc::clone(&host));
    let cli = TestPeer::connect(&harness.core, "dittoctl", None);
    wait_for_boot_sync(&state);
    let listed = cli.result(catalog::PROFILES_LIST, json!({}));
    let profiles = listed["profiles"].as_array().unwrap();
    let default_id = listed["active_profile"].clone();
    let baseline = get(&cli, &default_id);
    for (name, dock, launcher, layout, focus, hidden) in [
        (
            "開發",
            "ditto.dock.pill",
            "ditto.launcher.search",
            "ditto.layout.simple-tile",
            false,
            false,
        ),
        (
            "簡報",
            "ditto.dock.bottom",
            "ditto.launcher.grid",
            "ditto.layout.floating",
            true,
            true,
        ),
    ] {
        let summary = profiles.iter().find(|p| p["name"] == name).unwrap();
        let id = &summary["profile_id"];
        let original = get(&cli, id);
        let change = switch(&cli, id);
        assert_eq!(change.state, ChangeState::Committed, "{change:?}");
        assert_eq!(change.result, Some(ResultKind::Succeeded));
        assert_eq!(
            change.committed_revision.as_ref().unwrap(),
            original["revision"]["revision_id"].as_str().unwrap()
        );
        assert_eq!(get(&cli, id)["document"], original["document"]);
        assert_eq!(document(&cli), original["document"]);
        assert_eq!(head(&cli), original["profile"]["head_revision"]);
        let projection = state.lock().unwrap().committed.clone().unwrap();
        assert_eq!(
            projection
                .slots
                .iter()
                .find(|s| s.slot == "ui.dock")
                .unwrap()
                .package,
            dock
        );
        assert_eq!(
            projection
                .slots
                .iter()
                .find(|s| s.slot == "ui.launcher")
                .unwrap()
                .package,
            launcher
        );
        assert_eq!(projection.avatar.hidden, hidden);
        assert_eq!(
            cli.result(catalog::LAYOUT_GET, json!({}))["observed_strategy"],
            layout.strip_prefix("ditto.layout.").unwrap()
        );
        let host_state = host.lock().unwrap();
        let policy = host_state
            .entries
            .iter()
            .find(|e| e["package"] == "ditto.svc.notification-policy")
            .unwrap();
        assert_eq!(
            policy["config"]["rules"]["focus"]["enabled"]
                .as_bool()
                .unwrap_or(false),
            focus
        );
        drop(host_state);
        assert_eq!(
            original["document"]["appearance"],
            baseline["document"]["appearance"]
        );
        assert_eq!(
            original["document"]["shortcuts"],
            baseline["document"]["shortcuts"]
        );

        let undone = record(&cli.result(
            catalog::CHANGES_UNDO,
            json!({"change_id": change.change_id}),
        ));
        assert_eq!(undone.state, ChangeState::Committed, "{undone:?}");
        assert_eq!(
            cli.result(catalog::PROFILES_LIST, json!({}))["active_profile"],
            default_id
        );
        assert_eq!(document(&cli), baseline["document"]);
        assert_eq!(head(&cli), baseline["profile"]["head_revision"]);
        assert_eq!(switch(&cli, id).state, ChangeState::Committed);
        assert_eq!(switch(&cli, &default_id).state, ChangeState::Committed);
        for profile in profiles {
            let saved = get(&cli, &profile["profile_id"]);
            assert_eq!(saved["profile"]["head_revision"], profile["head_revision"]);
            assert_eq!(saved["history"].as_array().unwrap().len(), 1);
        }
    }
}

#[test]
fn builtin_documents_never_reference_absent_packages() {
    let harness = shipped_harness("builtin-missing-packages");
    let packages = harness
        .core
        .coordinate(Duration::from_secs(10), |co| co.packages())
        .unwrap();
    let subset = crate::projection::PackageSet::new(
        packages
            .rows()
            .filter(|row| {
                ![
                    "ditto.dock.pill",
                    "ditto.launcher.search",
                    "ditto.layout.simple-tile",
                    "ditto.svc.notification-policy",
                ]
                .contains(&row.summary.package_id.as_str())
            })
            .cloned()
            .collect(),
    );
    for (_, document) in crate::defaults::builtin_documents(&subset) {
        for entry in &document.entries {
            assert!(subset.get(&entry.package, &entry.version).is_some());
        }
        assert_eq!(
            document.slot_entry("ui.dock").unwrap().package,
            "ditto.dock.bottom"
        );
        assert_eq!(document.slot_entry("ui.dock").unwrap().config, json!({}));
    }
    for (_, document) in crate::defaults::builtin_documents(&Default::default()) {
        assert!(document.entries.is_empty());
        assert!(document.slots.is_empty());
    }
    let foreign = crate::projection::PackageSet::new(
        packages
            .rows()
            .cloned()
            .map(|mut row| {
                row.summary.source = "catalog".into();
                row
            })
            .collect(),
    );
    for (_, document) in crate::defaults::builtin_documents(&foreign) {
        assert!(document.entries.is_empty());
    }
}

#[test]
fn builtin_compositions_pass_preflight_with_shipped_config_schemas() {
    let harness = shipped_harness("builtin-preflight");
    let paths = Paths::under(&harness.root.join("store"));
    harness
        .core
        .coordinate(Duration::from_secs(10), move |co| {
            let packages = co.packages();
            let resolver = crate::projection::Resolver {
                packages: &packages,
                paths: &paths,
                grants: &[],
            };
            let origin = ditto_protocol::change::ChangeOrigin::Cli;
            let context = crate::preflight::Context {
                head_revision: "head",
                base_revision: "head",
                packages: &packages,
                resolver: &resolver,
                origin: &origin,
                session_locked: false,
                free_bytes: None,
                node_version: Some("22.23.2"),
                verify_trees: true,
            };
            let documents = crate::defaults::builtin_documents(&packages);
            for (name, doc) in &documents {
                assert_eq!(doc.entries.len(), 8);
                assert_eq!(doc.layout.workspace_grid, [3, 3]);
                assert!(doc.layout.rules.is_empty());
                assert!(doc.layout.regions.is_empty());
                let validation =
                    crate::preflight::run_target(&documents[0].1, doc.clone(), vec![], &context);
                assert!(
                    validation.reasons.is_empty(),
                    "{name}: {:?}",
                    validation.reasons
                );
                assert_eq!(doc.appearance, documents[0].1.appearance);
                assert_eq!(doc.shortcuts, documents[0].1.shortcuts);
            }
            assert_eq!(
                documents[1].1.slot_entry("ui.dock").unwrap().config["position"],
                "left"
            );
            assert_eq!(
                documents[2]
                    .1
                    .slot_entry("svc.notification_policy")
                    .unwrap()
                    .config["rules"]["focus"]["enabled"],
                true
            );
            assert!(documents[2].1.avatar.hidden);
            assert!(!documents[2].1.avatar.animations);
        })
        .unwrap();
}

/// Exercise switch/undo through the real coordinator without IPC. Identical
/// empty compositions need no Shell/hostd participant; the full recipes above
/// additionally have an IPC integration test for participant readback.
#[test]
fn switch_undo_restores_profile_identity_and_refuses_newer_edits_without_ipc() {
    use crate::coordinator::Proposal;
    use ditto_protocol::change::{ChangeMode, ChangeOp, ChangeOrigin};
    let root = root("switch-undo-direct");
    seed_store(
        &root,
        &plain_document("#123456"),
        &plain_document("#123456"),
        |_, _, _, _| Ok(()),
    );
    let core = start_at(&root, false);
    let harness = Harness { core, root };
    harness
        .core
        .coordinate(Duration::from_secs(10), |co| {
            let connection = co.store_ref().connection();
            let source = profiles::active_profile(connection).unwrap().unwrap();
            let (_, source_revision, doc) = profiles::head_document(connection, &source).unwrap();
            let (target, target_revision) = co
                .store()
                .write(|tx| {
                    profiles::create(
                        tx,
                        "測試目標",
                        &doc,
                        &RevisionOrigin::Create {
                            from: "empty".into(),
                        },
                    )
                })
                .unwrap();
            let propose_switch = |co: &mut crate::coordinator::Coordinator| {
                co.propose(
                    Proposal {
                        profile_id: Some(source.clone()),
                        base_revision: source_revision.revision_id.clone(),
                        ops: vec![ChangeOp::SwitchProfile {
                            to_profile: target.profile_id.clone(),
                            to_revision: None,
                        }],
                        mode: ChangeMode::Apply,
                        idempotency_key: None,
                        request_operation_id: None,
                        origin: ChangeOrigin::Cli,
                        subject: "cli".into(),
                        target: None,
                    },
                    None,
                )
                .unwrap()
            };
            let change = propose_switch(co);
            assert_eq!(change.state, ChangeState::Committed, "{change:?}");
            assert_eq!(
                change.committed_revision.as_ref(),
                Some(&target_revision.revision_id)
            );
            let undo = co
                .undo(&change.change_id, "cli", Some("undo-switch".into()), None)
                .unwrap();
            assert_eq!(undo.state, ChangeState::Committed, "{undo:?}");
            assert_eq!(
                undo.committed_revision.as_ref(),
                Some(&source_revision.revision_id)
            );
            assert_eq!(
                profiles::active_profile(co.store_ref().connection()).unwrap(),
                Some(source.clone())
            );
            assert_eq!(
                co.undo(&change.change_id, "cli", Some("undo-switch".into()), None)
                    .unwrap()
                    .change_id,
                undo.change_id
            );
            assert_eq!(
                profiles::head_document(co.store_ref().connection(), &source)
                    .unwrap()
                    .1
                    .revision_id,
                source_revision.revision_id
            );
            assert_eq!(
                profiles::head_document(co.store_ref().connection(), &target.profile_id)
                    .unwrap()
                    .1
                    .revision_id,
                target_revision.revision_id
            );
            let change = propose_switch(co);
            // A subsequent revision must block this undo, even with equal content.
            co.store()
                .write(|tx| {
                    let edit = profiles::insert_revision(
                        tx,
                        &target.profile_id,
                        Some(&target_revision.revision_id),
                        &doc,
                        &RevisionOrigin::Create {
                            from: "empty".into(),
                        },
                        None,
                    )?;
                    profiles::set_head(tx, &target.profile_id, &edit.revision_id)
                })
                .unwrap();
            assert!(co.undo(&change.change_id, "cli", None, None).is_err());
            assert_eq!(
                profiles::active_profile(co.store_ref().connection()).unwrap(),
                Some(target.profile_id)
            );
        })
        .unwrap();
}

#[test]
fn assistant_legacy_export_switch_undo_and_restart_store_roundtrip() {
    let harness = shipped_harness("assistant-roundtrip");
    harness
        .core
        .coordinate(Duration::from_secs(10), |co| {
            let packages = co.packages();
            let mut legacy = crate::defaults::empty_document();
            legacy.avatar.enabled = false;
            legacy.avatar.hidden = true;
            legacy.avatar.scale = 1.75;
            legacy.avatar.animations = false;
            legacy.avatar.output = Some("HDMI-A-2".into());
            legacy.avatar.corner = ditto_protocol::profile::AvatarCorner::TopLeft;
            let mut assistant = legacy.clone();
            assistant.avatar.presentation =
                Some(ditto_protocol::profile::AvatarPresentation::Assistant);
            for (name, doc) in [("legacy", &legacy), ("assistant", &assistant)] {
                let export = crate::exports::export(name, doc, &packages).unwrap();
                let (import, problems) =
                    crate::exports::validate(&serde_json::to_value(export).unwrap(), &packages);
                assert!(problems.is_empty(), "{problems:?}");
                assert_eq!(import.unwrap().document.digest(), doc.digest());
            }
            let paths = co.store_ref().paths().clone();
            let (old, new) = co
                .store()
                .write(|tx| {
                    let (old, _) =
                        profiles::create(tx, "legacy-check", &legacy, &RevisionOrigin::Import)?;
                    let (new, _) = profiles::create(
                        tx,
                        "assistant-check",
                        &assistant,
                        &RevisionOrigin::Import,
                    )?;
                    Ok((old, new))
                })
                .unwrap();
            // The storage operations used by profile switching and undo; the IPC
            // participant transaction is exercised by builtin_switches_* separately.
            for (id, expected) in [
                (&old.profile_id, &legacy),
                (&new.profile_id, &assistant),
                (&old.profile_id, &legacy),
            ] {
                co.store()
                    .write(|tx| profiles::set_active_profile(tx, id))
                    .unwrap();
                let reader = ditto_store::Store::open_reader(&paths).unwrap();
                assert_eq!(
                    profiles::active_profile(reader.connection())
                        .unwrap()
                        .as_deref(),
                    Some(id.as_str())
                );
                let (_, revision, doc) = profiles::head_document(reader.connection(), id).unwrap();
                assert_eq!(&doc, expected);
                assert_eq!(revision.document_sha256, expected.digest());
            }
        })
        .unwrap();
}

#[test]
fn assistant_and_legacy_survive_core_boot_from_a_closed_store() {
    for assistant in [false, true] {
        let root = root("assistant-restart");
        let paths = Paths::under(&root.join("store"));
        let mut document = crate::defaults::empty_document();
        document.avatar.presentation =
            assistant.then_some(ditto_protocol::profile::AvatarPresentation::Assistant);
        document.avatar.output = Some("HDMI-A-2".into());
        document.avatar.corner = ditto_protocol::profile::AvatarCorner::TopLeft;
        document.avatar.scale = 1.75;
        document.avatar.animations = false;
        let (profile, revision) = {
            let lock = ditto_store::WriterLock::acquire(&paths.lock()).unwrap();
            let (mut store, _) = ditto_store::Store::open_writer(&paths, &lock).unwrap();
            store
                .write(|tx| {
                    let result =
                        profiles::create(tx, "saved-entry", &document, &RevisionOrigin::Import)?;
                    profiles::set_active_profile(tx, &result.0.profile_id)?;
                    Ok(result)
                })
                .unwrap()
        };
        // The writer and its lock have closed. Core opens its own Store and
        // runs the real boot path, including the no-reseed upgrade rule.
        let core = start_at(&root, false);
        let harness = Harness { core, root };
        let actual = stored_get(&harness.core, &json!(profile.profile_id));
        assert_eq!(actual["document"], document.to_value());
        assert_eq!(actual["revision"]["document_sha256"], document.digest());
        assert_eq!(actual["profile"]["head_revision"], revision.revision_id);
        assert_eq!(
            stored_list(&harness.core)["profiles"]
                .as_array()
                .unwrap()
                .len(),
            1
        );
    }
}
