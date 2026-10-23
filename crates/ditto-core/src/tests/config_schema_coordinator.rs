//! #161 repair 1: the config_schema check through the real coordinator and
//! socket, for the paths an independent review found open (switch from a
//! non-active Profile, undo of an older change, install of a schema Core
//! cannot judge).
use super::builtin_profiles::shipped_harness;
use super::*;
use ditto_protocol::profile::{ProfileDocument, RevisionOrigin};
use ditto_store::profiles;

/// A shipped harness with a Shell and a hostd that accept every change.
fn desktop(label: &str) -> (Harness, Arc<TestPeer>, Vec<Arc<TestPeer>>) {
    let harness = shipped_harness(label);
    let state = Arc::new(Mutex::new(ShellState::default()));
    let shell = fake_shell(&harness.core, Arc::clone(&state));
    let host = fake_host(&harness.core, Arc::new(Mutex::new(HostState::default())));
    let cli = TestPeer::connect(&harness.core, "dittoctl", None);
    wait_for_boot_sync(&state);
    (harness, cli, vec![shell, host])
}

fn active(cli: &TestPeer) -> (String, String, ProfileDocument) {
    let got = cli.result(catalog::PROFILES_GET, json!({}));
    (
        got["profile"]["profile_id"].as_str().unwrap().into(),
        got["profile"]["head_revision"].as_str().unwrap().into(),
        serde_json::from_value(got["document"].clone()).unwrap(),
    )
}

fn active_id(cli: &TestPeer) -> Value {
    cli.result(catalog::PROFILES_LIST, json!({}))["active_profile"].clone()
}

fn dock_id(document: &ProfileDocument) -> String {
    let dock = document.slot_entry("ui.dock").unwrap();
    assert_eq!(dock.package, "ditto.dock.pill");
    dock.entry_id.clone()
}

/// Propose, and read back the record whether the change committed or was
/// refused in preflight (which answers with a `preflight_rejected` error).
fn propose(cli: &TestPeer, params: Value) -> ChangeRecord {
    let response = cli.call(catalog::CHANGES_PROPOSE, params);
    if let Some(result) = response.get("result") {
        return record(result);
    }
    assert_eq!(
        response["error"]["name"], "preflight_rejected",
        "{response}"
    );
    let change_id = response["error"]["data"]["change_id"].clone();
    record(&cli.result(catalog::CHANGES_GET, json!({"change_id": change_id})))
}

fn whys(record: &ChangeRecord) -> Vec<String> {
    record
        .reasons
        .iter()
        .filter_map(|r| {
            r.detail
                .get("why")
                .and_then(Value::as_str)
                .map(String::from)
        })
        .collect()
}

/// An export of the active Profile with the dock's config replaced.
fn export_with_dock(cli: &TestPeer, profile: &str, config: Value) -> Value {
    let mut export =
        cli.result(catalog::PROFILES_EXPORT, json!({"profile_id": profile}))["export"].clone();
    let mut document: ProfileDocument = serde_json::from_value(export["document"].clone()).unwrap();
    let dock = dock_id(&document);
    document.entry_mut(&dock).unwrap().config = config;
    export["document_sha256"] = json!(document.digest());
    export["document"] = serde_json::to_value(&document).unwrap();
    export
}

/// P1-a: a switch is judged against the Profile that is active, whatever
/// Profile the proposal names; a switch proposed from another Profile is
/// refused, and nothing becomes active until the config is fixed.
#[test]
fn a_switch_cannot_skip_the_config_check_by_starting_from_its_own_target() {
    let (_harness, cli, _participants) = desktop("cs-self-switch");
    let (original, _, _) = active(&cli);
    let bad = export_with_dock(&cli, &original, json!({"position": 3}));
    let checked = cli.result(catalog::PROFILES_IMPORT_VALIDATE, json!({"export": bad}));
    assert_eq!(checked["importable"], true, "{checked}");
    assert!(checked["problems"]
        .as_array()
        .unwrap()
        .iter()
        .any(|p| p["kind"] == "schema_invalid"
            && p["blocking"] == false
            && p["detail"]["why"] == "config_schema_violation"));
    let imported = cli.result(
        catalog::PROFILES_IMPORT,
        json!({"export": bad, "name": "壞的匯入"}),
    );
    let imported_id = imported["profile_id"].as_str().unwrap().to_string();
    let imported_head = imported["head_revision"].as_str().unwrap().to_string();

    // The bypass: the proposal names the imported Profile as its own base.
    let own = propose(
        &cli,
        json!({"profile_id": imported_id, "base_revision": imported_head,
               "ops": [{"op": "switch_profile", "to_profile": imported_id}]}),
    );
    assert_eq!(own.state, ChangeState::Rejected, "{own:?}");
    assert!(
        whys(&own).contains(&"switch_not_from_active_profile".to_string()),
        "{:?}",
        own.reasons
    );
    assert_eq!(active_id(&cli), json!(original));

    // The ordinary switch from the active Profile checks the config.
    let (_, head, _) = active(&cli);
    let plain = propose(
        &cli,
        json!({"base_revision": head, "ops": [{"op": "switch_profile", "to_profile": imported_id}]}),
    );
    assert_eq!(plain.state, ChangeState::Rejected, "{plain:?}");
    let reason = plain
        .reasons
        .iter()
        .find(|r| r.detail.get("why") == Some(&json!("config_schema_violation")))
        .unwrap_or_else(|| panic!("{:?}", plain.reasons));
    assert_eq!(reason.detail["pointer"], json!("/position"));
    assert_eq!(active_id(&cli), json!(original));

    // With the config fixed (a corrected export imported again) the switch
    // goes through and the new Profile is active.
    let good = export_with_dock(&cli, &original, json!({"position": "left"}));
    let fixed = cli.result(
        catalog::PROFILES_IMPORT,
        json!({"export": good, "name": "修正後的匯入"}),
    );
    let fixed_id = fixed["profile_id"].clone();
    let switched = propose(
        &cli,
        json!({"base_revision": head, "ops": [{"op": "switch_profile", "to_profile": fixed_id}]}),
    );
    assert_eq!(switched.state, ChangeState::Committed, "{switched:?}");
    assert_eq!(active_id(&cli), fixed_id);
}

/// P1-b: undoing an older change puts back a config Core had stored, even
/// when the schema refuses it; a client writing the same value is checked.
#[test]
fn undo_of_an_older_change_restores_a_stored_config_but_a_client_cannot_write_it() {
    let (harness, cli, _participants) = desktop("cs-undo-older");
    let (profile, head, document) = active(&cli);
    let dock = dock_id(&document);
    // A config stored before #161 that the shipped schema refuses.
    let mut legacy = document.clone();
    legacy.entry_mut(&dock).unwrap().config = json!({"position": "top"});
    let stored = legacy.clone();
    let (profile_for_store, head_for_store) = (profile.clone(), head.clone());
    harness
        .core
        .coordinate(Duration::from_secs(10), move |co| {
            co.store()
                .write(|tx| {
                    let revision = profiles::insert_revision(
                        tx,
                        &profile_for_store,
                        Some(&head_for_store),
                        &stored,
                        &RevisionOrigin::Import,
                        None,
                    )?;
                    profiles::set_head(tx, &profile_for_store, &revision.revision_id)
                })
                .unwrap()
        })
        .unwrap();
    let (_, legacy_head, _) = active(&cli);
    assert_ne!(legacy_head, head);

    let fix = propose(
        &cli,
        json!({"base_revision": legacy_head, "ops": [
            {"op": "set_entry_config", "entry_id": dock, "after": {"position": "left"}}]}),
    );
    assert_eq!(fix.state, ChangeState::Committed, "{fix:?}");
    let (_, after_fix, _) = active(&cli);
    let unrelated = propose(
        &cli,
        json!({"base_revision": after_fix, "ops": [
            {"op": "set_value", "path": "/appearance/tokens/accent", "after": "#123456"}]}),
    );
    assert_eq!(unrelated.state, ChangeState::Committed, "{unrelated:?}");

    // A client sending the old value is checked like any other write.
    let (_, now, _) = active(&cli);
    let client = propose(
        &cli,
        json!({"base_revision": now, "ops": [
            {"op": "set_entry_config", "entry_id": dock, "after": {"position": "top"}}]}),
    );
    assert_eq!(client.state, ChangeState::Rejected, "{client:?}");
    assert!(whys(&client).contains(&"config_schema_violation".to_string()));
    // The restore marker is Core's own: a request cannot carry it.
    for field in ["restored_from", "restores", "origin"] {
        let forged = cli.call(
            catalog::CHANGES_PROPOSE,
            json!({"base_revision": now, field: {"kind": "undo", "undoes": fix.change_id},
                   "ops": [{"op": "set_entry_config", "entry_id": dock, "after": {"position": "top"}}]}),
        );
        // Refused as a malformed request, before any preflight runs.
        assert_eq!(
            forged["error"]["name"], "invalid_params",
            "{field}: {forged}"
        );
    }
    let (_, still, after_client) = active(&cli);
    assert_eq!(still, now);
    assert_eq!(
        after_client.entry(&dock).unwrap().config,
        json!({"position": "left"})
    );

    // Undo of the older fix: not the newest change, no overlapping path.
    let response = cli.call(catalog::CHANGES_UNDO, json!({"change_id": fix.change_id}));
    let undone = match response.get("result") {
        Some(result) => record(result),
        None => record(&cli.result(
            catalog::CHANGES_GET,
            json!({"change_id": response["error"]["data"]["change_id"]}),
        )),
    };
    assert_eq!(undone.state, ChangeState::Committed, "{undone:?}");
    let (_, _, restored) = active(&cli);
    assert_eq!(
        restored.entry(&dock).unwrap().config,
        json!({"position": "top"})
    );
    assert_eq!(restored.appearance.tokens["accent"], "#123456");
}

/// P2: a package whose config_schema Core cannot judge is refused when it is
/// installed or seeded, before it is stored.
#[test]
fn install_and_seeding_refuse_a_config_schema_outside_the_subset() {
    let root = root("cs-install");
    let builtin = root.join("builtin");
    builtin_packages(&builtin);
    let seeded_bad = manifest(
        "ditto.test.seededschema",
        "qml_provider",
        "qml",
        &["ui.dock"],
        json!({"config_schema": {"type": "object", "x-widget": "slider"}}),
    );
    pack(&builtin, &seeded_bad);
    let core = start_at(&root, false);
    let harness = Harness { core, root };
    let cli = TestPeer::connect(&harness.core, "dittoctl", None);
    let installed = |cli: &TestPeer, id: &str| {
        cli.result(catalog::PLUGINS_LIST, json!({}))["packages"]
            .as_array()
            .unwrap()
            .iter()
            .any(|p| p["package_id"] == json!(id))
    };
    assert!(!installed(&cli, "ditto.test.seededschema"));
    assert!(installed(&cli, "ditto.dock.pill"), "seeding went on");

    let extra = harness.root.join("extra");
    std::fs::create_dir_all(&extra).unwrap();
    let bad = manifest(
        "ditto.test.badschema",
        "qml_provider",
        "qml",
        &["ui.dock"],
        json!({"config_schema": {"type": "object", "properties": {"x": 3}}}),
    );
    pack(&extra, &bad);
    let job = cli.call(
        catalog::PLUGINS_INSTALL,
        json!({"path": extra.join("ditto.test.badschema-1.0.0.dittopkg").display().to_string(),
               "idempotency_key": "cs-install-bad"}),
    );
    assert_eq!(job["result"]["state"], "failed", "{job}");
    assert!(!installed(&cli, "ditto.test.badschema"));
    let inspected = cli.result(
        catalog::PLUGINS_INSPECT,
        json!({"path": extra.join("ditto.test.badschema-1.0.0.dittopkg").display().to_string()}),
    );
    assert!(
        inspected.to_string().contains("config_schema/properties/x"),
        "{inspected}"
    );

    let good = manifest(
        "ditto.test.goodschema",
        "qml_provider",
        "qml",
        &["ui.dock"],
        json!({"config_schema": {"type": "object", "properties": {"x": {"type": "integer"}}}}),
    );
    pack(&extra, &good);
    let job = cli.call(
        catalog::PLUGINS_INSTALL,
        json!({"path": extra.join("ditto.test.goodschema-1.0.0.dittopkg").display().to_string(),
               "idempotency_key": "cs-install-good"}),
    );
    assert_eq!(job["result"]["state"], "succeeded", "{job}");
    assert!(installed(&cli, "ditto.test.goodschema"));
}
