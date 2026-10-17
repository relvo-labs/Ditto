//! G3 transactions against the real Core and SQLite, with controlled Shell
//! failures. Forged native validation is ONLY test setup, not OS evidence.
use super::*;
use ditto_protocol::generation::*;

fn artifact(mut value: Value) -> GeneratedArtifact {
    value.as_object_mut().unwrap().remove("_meta");
    serde_json::from_value(value).unwrap()
}

fn publish(
    core: &Arc<Core>,
    cli: &TestPeer,
    version: &str,
    parent: Option<&GeneratedArtifact>,
    data: DataPlan,
) -> GeneratedArtifact {
    let mut description = Description::parse(include_bytes!(
        "../../../ditto-generation/examples/tasks-summary.json"
    ))
    .unwrap();
    description.version = version.into();
    description.data = data;
    let mut a = artifact(cli.result(
        catalog::DEVELOPMENT_CREATE,
        json!({
            "description":description,"parent_id":parent.map(|a| &a.artifact_id),
            "request_summary":"generated transaction test","idempotency_key":version
        }),
    ));
    a.state = ArtifactState::Validated;
    a.validation = Some(GenerationValidation {
        bundle_sha256: a.bundle_sha256.clone(),
        boundary: GenerationBoundary {
            enforcement: Enforcement::Full,
            policy: "generated-templates-v1".into(),
            landlock_abi: 8,
            files: true,
            network: true,
            process_exec_blocked: true,
            memory_max: 512 * 1024 * 1024,
            cpu_max: "100000 100000".into(),
            pids_max: 64,
            deadline_ms: 15000,
            cleanup_complete: true,
            reasons: vec![],
            unit: Some("ditto-generation-unit.service".into()),
            cgroup: Some("/fixture/ditto-generation-unit.service".into()),
            runner_pid: Some(1),
        },
        stages: VALIDATION_STAGES
            .into_iter()
            .map(|stage| StageEvidence {
                stage,
                result: StageResult::Passed,
                diagnostic: "unit fixture only".into(),
            })
            .collect(),
        test_data: true,
        preview_opened: false,
        diagnostics: vec![],
    });
    let saved = a.clone();
    core.coordinate(Duration::from_secs(5), move |c| {
        c.store()
            .write(|tx| ditto_store::generated::save(tx, &saved))
    })
    .unwrap()
    .unwrap();
    artifact(cli.result(
        catalog::DEVELOPMENT_PUBLISH,
        json!({"artifact_id":a.artifact_id}),
    ))
}

fn activate(cli: &TestPeer, a: &GeneratedArtifact, key: &str) -> ChangeRecord {
    record(&cli.result(
        catalog::DEVELOPMENT_ACTIVATE,
        json!({"artifact_id":a.artifact_id,"base_revision":head(cli),"idempotency_key":key}),
    ))
}
fn data(version: u32, field: &str, from: Option<(u32, &str, RollbackPolicy)>) -> DataPlan {
    DataPlan {
        schema_version: version,
        fields: [(field.into(), DataType::Text)].into(),
        migration: from.map(|(from_version, old, rollback)| DataMigration {
            from_version,
            rename: [(old.into(), field.into())].into(),
            defaults: Default::default(),
            remove: vec![],
            rollback,
        }),
    }
}
fn write_note(cli: &TestPeer, a: &GeneratedArtifact, field: &str, text: &str) {
    let current = cli.result(
        catalog::DEVELOPMENT_DATA_GET,
        json!({"artifact_id":a.artifact_id}),
    );
    cli.result(catalog::DEVELOPMENT_DATA_WRITE,json!({"artifact_id":a.artifact_id,"expected_revision":current["revision"],"payload":{field:text}}));
}
fn assert_restored(
    cli: &TestPeer,
    state: &Arc<Mutex<ShellState>>,
    a: &GeneratedArtifact,
    b: &GeneratedArtifact,
    before: &str,
    failed: &ChangeRecord,
) {
    assert_eq!(head(cli), before);
    let actual = cli.result(
        catalog::DEVELOPMENT_DATA_GET,
        json!({"artifact_id":a.artifact_id}),
    );
    assert_eq!(actual["payload"], json!({"note":"original data"}));
    assert!(state
        .lock()
        .unwrap()
        .committed
        .as_ref()
        .unwrap()
        .slots
        .iter()
        .any(|slot| slot.config["artifact_id"] == a.artifact_id));
    let candidate = cli.result(
        catalog::DEVELOPMENT_GET,
        json!({"artifact_id":b.artifact_id}),
    );
    assert_eq!(candidate["state"], "failed");
    assert!(!candidate["source_files"].as_object().unwrap().is_empty());
    assert!(candidate["activations"]
        .as_array()
        .unwrap()
        .iter()
        .any(|r| r["change_id"] == failed.change_id && r["state"] == failed.state.as_str()));
    assert!(!failed.items.is_empty());
}

#[test]
fn generated_load_health_and_wrong_version_readback_restore_provider_and_data() {
    for point in ["load", "health", "readback"] {
        let h = harness(&format!("generated-{point}-failure"));
        let state = Arc::new(Mutex::new(ShellState::default()));
        let _shell = fake_shell(&h.core, Arc::clone(&state));
        let cli = TestPeer::connect(&h.core, "dittoctl", None);
        wait_for_boot_sync(&state);
        let a = publish(&h.core, &cli, "1.0.0", None, data(1, "note", None));
        assert_eq!(activate(&cli, &a, "initial").state, ChangeState::Committed);
        write_note(&cli, &a, "note", "original data");
        let b = publish(
            &h.core,
            &cli,
            "2.0.0",
            Some(&a),
            data(2, "title", Some((1, "note", RollbackPolicy::Snapshot))),
        );
        let before = head(&cli);
        {
            let mut shell = state.lock().unwrap();
            match point {
                "load" => shell.broken_package = Some(a.description.plugin_id.clone()),
                "health" => shell.unhealthy_package = Some(a.description.plugin_id.clone()),
                _ => shell.lie_after_commit = true,
            }
        }
        let failed = activate(&cli, &b, "failure");
        assert_eq!(
            failed.state,
            if point == "load" {
                ChangeState::Aborted
            } else {
                ChangeState::RolledBack
            },
            "{point}: {failed:?}"
        );
        assert_restored(&cli, &state, &a, &b, &before, &failed);
    }
}

#[test]
fn two_generated_schema_modifications_can_return_to_first_version() {
    let h = harness("generated-two-upgrades");
    let state = Arc::new(Mutex::new(ShellState::default()));
    let _shell = fake_shell(&h.core, Arc::clone(&state));
    let cli = TestPeer::connect(&h.core, "dittoctl", None);
    wait_for_boot_sync(&state);
    let a = publish(&h.core, &cli, "1.0.0", None, data(1, "note", None));
    assert_eq!(activate(&cli, &a, "initial").state, ChangeState::Committed);
    write_note(&cli, &a, "note", "first version data");
    let b = publish(
        &h.core,
        &cli,
        "2.0.0",
        Some(&a),
        data(2, "title", Some((1, "note", RollbackPolicy::Snapshot))),
    );
    assert_eq!(
        activate(&cli, &b, "upgrade-b").state,
        ChangeState::Committed
    );
    write_note(&cli, &b, "title", "second version data");
    let c = publish(
        &h.core,
        &cli,
        "3.0.0",
        Some(&b),
        data(3, "label", Some((2, "title", RollbackPolicy::Snapshot))),
    );
    assert_eq!(
        activate(&cli, &c, "upgrade-c").state,
        ChangeState::Committed
    );
    write_note(&cli, &c, "label", "third version data");
    assert_eq!(
        activate(&cli, &a, "back-to-first").state,
        ChangeState::Committed
    );
    assert_eq!(
        cli.result(
            catalog::DEVELOPMENT_DATA_GET,
            json!({"artifact_id":a.artifact_id})
        )["payload"],
        json!({"note":"first version data"})
    );
    assert_eq!(
        cli.call(
            catalog::DEVELOPMENT_DATA_GET,
            json!({"artifact_id":c.artifact_id})
        )["error"]["name"],
        "conflict"
    );
    assert!(state
        .lock()
        .unwrap()
        .committed
        .as_ref()
        .unwrap()
        .slots
        .iter()
        .any(|slot| slot.config["artifact_id"] == a.artifact_id));
    assert_eq!(
        cli.result(
            catalog::DEVELOPMENT_GET,
            json!({"artifact_id":a.artifact_id})
        )["description"],
        json!(a.description)
    );
}

#[test]
fn generated_data_snapshot_commit_failure_rolls_back_the_real_transaction() {
    let h = harness("generated-snapshot-commit-failure");
    let state = Arc::new(Mutex::new(ShellState::default()));
    let _shell = fake_shell(&h.core, Arc::clone(&state));
    let cli = TestPeer::connect(&h.core, "dittoctl", None);
    wait_for_boot_sync(&state);
    let a = publish(&h.core, &cli, "1.0.0", None, data(1, "note", None));
    assert_eq!(activate(&cli, &a, "initial").state, ChangeState::Committed);
    write_note(&cli, &a, "note", "original data");
    let b = publish(
        &h.core,
        &cli,
        "2.0.0",
        Some(&a),
        data(2, "title", Some((1, "note", RollbackPolicy::Snapshot))),
    );
    h.core.coordinate(Duration::from_secs(5),|c|c.store().write(|tx|{
        tx.execute_batch("CREATE TEMP TRIGGER fail_generated_snapshot BEFORE INSERT ON generated_data_snapshots BEGIN SELECT RAISE(ABORT,'injected snapshot storage failure'); END;")?;
        Ok(())
    })).unwrap().unwrap();
    let before = head(&cli);
    let failed = activate(&cli, &b, "failed-commit");
    assert_eq!(failed.state, ChangeState::RolledBack);
    assert_restored(&cli, &state, &a, &b, &before, &failed);
}

#[test]
fn irreversible_and_corrupt_snapshot_rollbacks_keep_new_data_and_revision() {
    for policy in [RollbackPolicy::Unavailable, RollbackPolicy::Snapshot] {
        let h = harness("generated-rollback-refusal");
        let state = Arc::new(Mutex::new(ShellState::default()));
        let _shell = fake_shell(&h.core, Arc::clone(&state));
        let cli = TestPeer::connect(&h.core, "dittoctl", None);
        wait_for_boot_sync(&state);
        let a = publish(&h.core, &cli, "1.0.0", None, data(1, "note", None));
        assert_eq!(activate(&cli, &a, "initial").state, ChangeState::Committed);
        write_note(&cli, &a, "note", "old data");
        let b = publish(
            &h.core,
            &cli,
            "2.0.0",
            Some(&a),
            data(2, "title", Some((1, "note", policy))),
        );
        assert_eq!(activate(&cli, &b, "upgrade").state, ChangeState::Committed);
        write_note(&cli, &b, "title", "new data remains");
        if policy == RollbackPolicy::Snapshot {
            h.core
                .coordinate(Duration::from_secs(5), |c| {
                    c.store().write(|tx| {
                        tx.execute(
                            "UPDATE generated_data_snapshots SET payload_json='corrupt snapshot'",
                            [],
                        )?;
                        Ok(())
                    })
                })
                .unwrap()
                .unwrap();
        }
        let before = head(&cli);
        let refused=cli.call(catalog::DEVELOPMENT_ACTIVATE,json!({"artifact_id":a.artifact_id,"base_revision":before,"idempotency_key":"refused-rollback"}));
        assert_eq!(refused["error"]["name"], "preflight_rejected");
        assert_eq!(head(&cli), before);
        assert_eq!(
            cli.result(
                catalog::DEVELOPMENT_DATA_GET,
                json!({"artifact_id":b.artifact_id})
            )["payload"],
            json!({"title":"new data remains"})
        );
        assert_eq!(
            cli.call(
                catalog::DEVELOPMENT_DATA_GET,
                json!({"artifact_id":a.artifact_id})
            )["error"]["name"],
            "conflict"
        );
        assert!(state
            .lock()
            .unwrap()
            .committed
            .as_ref()
            .unwrap()
            .slots
            .iter()
            .any(|slot| slot.config["artifact_id"] == b.artifact_id));
    }
}

#[test]
fn generated_write_rechecks_a_previously_authorized_but_revoked_grant() {
    let h = harness("generated-revoked-before-write");
    let description = Description::parse(include_bytes!(
        "../../../ditto-generation/examples/tasks-summary.json"
    ))
    .unwrap();
    let plugin = description.plugin_id.clone();
    let grant = h
        .core
        .coordinate(Duration::from_secs(5), move |c| {
            c.store().write(|tx| {
                ditto_store::grants::insert(
                    tx,
                    &ditto_store::grants::NewGrant {
                        grant_id: None,
                        subject: "agent",
                        scope: catalog::scope::PLUGINS_DEVELOP,
                        resource: Some(&plugin),
                        expires_at: None,
                        granted_by: "cli",
                        idempotency_key: Some("development-test"),
                    },
                )
            })
        })
        .unwrap()
        .unwrap();
    let (sink, _) = mpsc::channel();
    let caller = crate::router::Caller {
        subject: ditto_protocol::Subject("agent".into()),
        kind: "agent".into(),
        connection_id: "unit-authorized-agent".into(),
        sink,
        gone: Arc::new(std::sync::atomic::AtomicBool::new(false)),
    };
    let contract = catalog::contract(catalog::DEVELOPMENT_CREATE).unwrap();
    let params=json!({"description":description,"request_summary":"must not survive revocation","idempotency_key":"revoked-candidate"}).as_object().unwrap().clone();
    crate::router::authorize(&h.core, &caller, &contract, &params).unwrap();
    h.core
        .coordinate(Duration::from_secs(5), move |c| {
            c.store()
                .write(|tx| ditto_store::grants::revoke(tx, &grant.grant_id))
        })
        .unwrap()
        .unwrap();
    // This provider call represents an invocation that passed routing before
    // a queued revocation. It must check again at its serialized write point.
    let call = crate::router::Call {
        id: "unit-call",
        contract: &contract,
        params,
        operation_id: None,
        deadline: Duration::from_secs(5),
        started: Instant::now(),
        approved_once: false,
    };
    let error = crate::generation::dispatch(&h.core, &caller, &call).unwrap_err();
    assert_eq!(error.name, ErrorName::PermissionDenied);
    assert!(h
        .core
        .read(ditto_store::generated::list)
        .unwrap()
        .is_empty());
}

#[test]
fn irreversible_middle_and_stale_sibling_snapshot_refuse_without_changing_state() {
    for stale_sibling in [false, true] {
        let h = harness("generated-middle-lineage-refusal");
        let state = Arc::new(Mutex::new(ShellState::default()));
        let _shell = fake_shell(&h.core, Arc::clone(&state));
        let cli = TestPeer::connect(&h.core, "dittoctl", None);
        wait_for_boot_sync(&state);
        let mut initial = data(1, "x", None);
        initial.fields.insert("y".into(), DataType::Text);
        let a = publish(&h.core, &cli, "1.0.0", None, initial);
        assert_eq!(activate(&cli, &a, "initial").state, ChangeState::Committed);
        write_note(&cli, &a, "x", "original x");
        if stale_sibling {
            let b = publish(
                &h.core,
                &cli,
                "2.0.0",
                Some(&a),
                data(2, "y", Some((1, "x", RollbackPolicy::Snapshot))),
            );
            assert_eq!(
                activate(&cli, &b, "old-branch").state,
                ChangeState::Committed
            );
            assert_eq!(
                activate(&cli, &a, "old-branch-back").state,
                ChangeState::Committed
            );
            write_note(&cli, &a, "x", "later data must remain");
        }
        let b = publish(
            &h.core,
            &cli,
            "2.1.0",
            Some(&a),
            data(2, "y", Some((1, "x", RollbackPolicy::Unavailable))),
        );
        assert_eq!(
            activate(&cli, &b, "irreversible-middle").state,
            ChangeState::Committed
        );
        let c = publish(
            &h.core,
            &cli,
            "3.0.0",
            Some(&b),
            DataPlan {
                schema_version: 3,
                fields: b.description.data.fields.clone(),
                migration: Some(DataMigration {
                    from_version: 2,
                    rename: Default::default(),
                    defaults: Default::default(),
                    remove: vec![],
                    rollback: if stale_sibling {
                        RollbackPolicy::Snapshot
                    } else {
                        RollbackPolicy::Compatible
                    },
                }),
            },
        );
        assert_eq!(activate(&cli, &c, "last-hop").state, ChangeState::Committed);
        let before = head(&cli);
        let read_data = || {
            let mut value = cli.result(
                catalog::DEVELOPMENT_DATA_GET,
                json!({"artifact_id":c.artifact_id}),
            );
            value.as_object_mut().unwrap().remove("_meta");
            value
        };
        let before_data = read_data();
        let before_artifact = artifact(cli.result(
            catalog::DEVELOPMENT_GET,
            json!({"artifact_id":c.artifact_id}),
        ));
        let result = cli.call(
            catalog::DEVELOPMENT_ACTIVATE,
            json!({"artifact_id":a.artifact_id,"base_revision":before,"idempotency_key":"refused"}),
        );
        assert_eq!(result["error"]["name"], "preflight_rejected", "{result}");
        assert_eq!(head(&cli), before);
        assert_eq!(read_data(), before_data);
        assert_eq!(
            before_data["payload"],
            json!({"y":if stale_sibling { "later data must remain" } else { "original x" }})
        );
        assert_eq!(
            artifact(cli.result(
                catalog::DEVELOPMENT_GET,
                json!({"artifact_id":c.artifact_id})
            )),
            before_artifact
        );
        assert_eq!(
            cli.call(
                catalog::DEVELOPMENT_DATA_GET,
                json!({"artifact_id":a.artifact_id})
            )["error"]["name"],
            "conflict"
        );
        assert!(state
            .lock()
            .unwrap()
            .committed
            .as_ref()
            .unwrap()
            .slots
            .iter()
            .any(|slot| slot.config["artifact_id"] == c.artifact_id));
    }
}

#[test]
fn generated_projection_omits_non_intact_or_unapproved_packages() {
    let h = harness("generated-projection-integrity");
    // Pure projection fixture: no RPC or native execution is needed.
    let a = h
        .core
        .coordinate(Duration::from_secs(5), |c| {
            c.store().write(|tx| {
                let description = Description::parse(include_bytes!(
                    "../../../ditto-generation/examples/tasks-summary.json"
                ))
                .unwrap();
                let mut a = ditto_store::generated::create(
                    tx,
                    &GenerateInput {
                        description,
                        request_summary: "projection fixture".into(),
                        parent_id: None,
                        idempotency_key: "projection".into(),
                    },
                    GenerationOrigin {
                        request_summary: "projection fixture".into(),
                        turn_id: None,
                        model: None,
                    },
                )?;
                let vector: Value = serde_json::from_str(include_str!(
                    "../../../../tests/contract-vectors/0.3/shape-generation-validation-full.json"
                ))
                .unwrap();
                let mut report: GenerationValidation =
                    serde_json::from_value(vector["value"].clone()).unwrap();
                report.bundle_sha256 = a.bundle_sha256.clone();
                a.validation = Some(report);
                a.state = ArtifactState::Published;
                ditto_store::generated::save(tx, &a)?;
                ditto_store::packages::insert(
                    tx,
                    &ditto_store::packages::Unpacked {
                        sha256: a.bundle_sha256.trim_start_matches("sha256:").into(),
                        tree_sha256: "fixture".into(),
                        manifest: a.manifest.clone(),
                        directory: std::path::PathBuf::from("/fixture"),
                        already_present: false,
                    },
                    "generated",
                    None,
                )?;
                Ok(a)
            })
        })
        .unwrap()
        .unwrap();
    let paths = &h.core.paths;
    let mut document = h
        .core
        .read(|c| {
            let profile = ditto_store::profiles::active_profile(c)?.unwrap();
            Ok(ditto_store::profiles::head_document(c, &profile)?.2)
        })
        .unwrap();
    document.entries.push(ditto_protocol::profile::EntrySpec {
        entry_id: "ent-generated".into(),
        package: a.description.plugin_id.clone(),
        version: a.description.version.clone(),
        host: ditto_protocol::profile::HostKind::Qml,
        config: json!({}),
        disabled: false,
        area: Some("ui.generated_panel".into()),
    });
    let mut rows = h.core.read(ditto_store::packages::list).unwrap();
    let index = rows.iter().position(|r| r.generated.is_some()).unwrap();
    for condition in ["intact", "tampered", "unapproved", "missing"] {
        rows[index].generated = Some(a.clone());
        match condition {
            "tampered" => rows[index]
                .generated
                .as_mut()
                .unwrap()
                .source_files
                .insert("changed.qml".into(), "changed".into()),
            "unapproved" => {
                rows[index].generated.as_mut().unwrap().state = ArtifactState::Candidate;
                None
            }
            "missing" => {
                rows[index].generated = None;
                None
            }
            _ => None,
        };
        let packages = crate::projection::PackageSet::new(rows.clone());
        let projected = crate::projection::shell(
            &document,
            &crate::projection::Resolver {
                packages: &packages,
                paths,
                grants: &[],
            },
        );
        let rendered = projected
            .slots
            .iter()
            .find(|s| s.entry_id == "ent-generated");
        assert_eq!(rendered.is_some(), condition == "intact");
        if let Some(binding) = rendered {
            assert_eq!(binding.qml_url, "ditto-generated:fixed");
        }
    }
}
