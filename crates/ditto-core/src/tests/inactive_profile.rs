//! #169: a ChangeSet on a Profile that is not active edits that Profile's
//! document only. The desktop shows the active Profile, so no participant
//! hears of the change; switching to the Profile later is what projects it.
//! The same holds for undo, timed revert and rescue restore when the Profile
//! they act on is not the active one.
use super::builtin_profiles::shipped_harness;
use super::*;
use ditto_protocol::{
    change::{ChangeOrigin, Confirmation},
    profile::{ProfileDocument, RevisionOrigin},
};
use ditto_store::profiles;

struct Desktop {
    harness: Harness,
    cli: Arc<TestPeer>,
    shell: Arc<Mutex<ShellState>>,
    host: Arc<Mutex<HostState>>,
    _peers: Vec<Arc<TestPeer>>,
}

/// The shipped compositions (預設 active, 開發 and 簡報 stored) with a Shell
/// and a hostd that accept every change and remember every change id they
/// were asked to prepare.
fn desktop(label: &str) -> Desktop {
    let harness = shipped_harness(label);
    let shell = Arc::new(Mutex::new(ShellState::default()));
    let host = Arc::new(Mutex::new(HostState::default()));
    let shell_peer = fake_shell(&harness.core, Arc::clone(&shell));
    let host_peer = fake_host(&harness.core, Arc::clone(&host));
    let cli = TestPeer::connect(&harness.core, "dittoctl", None);
    wait_for_boot_sync(&shell);
    Desktop {
        harness,
        cli,
        shell,
        host,
        _peers: vec![shell_peer, host_peer],
    }
}

impl Desktop {
    fn active_profile(&self) -> String {
        self.cli.result(catalog::PROFILES_LIST, json!({}))["active_profile"]
            .as_str()
            .unwrap()
            .into()
    }

    fn profile_named(&self, name: &str) -> String {
        self.cli.result(catalog::PROFILES_LIST, json!({}))["profiles"]
            .as_array()
            .unwrap()
            .iter()
            .find(|p| p["name"] == json!(name))
            .unwrap_or_else(|| panic!("no profile named {name}"))["profile_id"]
            .as_str()
            .unwrap()
            .into()
    }

    fn head_of(&self, profile: &str) -> (String, ProfileDocument) {
        let got = self
            .cli
            .result(catalog::PROFILES_GET, json!({"profile_id": profile}));
        (
            got["profile"]["head_revision"].as_str().unwrap().into(),
            serde_json::from_value(got["document"].clone()).unwrap(),
        )
    }

    /// Propose; a preflight refusal is read back as its record.
    fn propose(&self, params: Value) -> ChangeRecord {
        let response = self.cli.call(catalog::CHANGES_PROPOSE, params);
        settle(&self.cli, response)
    }

    fn undo(&self, change_id: &str) -> ChangeRecord {
        let response = self
            .cli
            .call(catalog::CHANGES_UNDO, json!({"change_id": change_id}));
        settle(&self.cli, response)
    }

    fn get(&self, change_id: &str) -> ChangeRecord {
        record(
            &self
                .cli
                .result(catalog::CHANGES_GET, json!({"change_id": change_id})),
        )
    }

    /// What the Shell shows now.
    fn live_shell(&self) -> ShellProjection {
        self.shell.lock().unwrap().committed.clone().unwrap()
    }

    /// Every participant that was asked to prepare this change.
    fn reached(&self, change_id: &str) -> Vec<&'static str> {
        let mut reached = Vec::new();
        if self
            .shell
            .lock()
            .unwrap()
            .candidates
            .contains_key(change_id)
        {
            reached.push("shell");
        }
        if self.host.lock().unwrap().candidates.contains_key(change_id) {
            reached.push("hostd");
        }
        reached
    }

    /// `changes.get` and `changes.list` both say the change was saved to
    /// `profile_name` and not applied (#169 repair 1). Read as JSON, so the
    /// wire form is what is checked.
    fn assert_saved_only(&self, change_id: &str, profile_name: &str) {
        let expected = json!({"reason": "inactive_profile", "profile_name": profile_name});
        let got = self
            .cli
            .result(catalog::CHANGES_GET, json!({"change_id": change_id}));
        assert_eq!(got["saved_only"], expected, "changes.get: {got}");
        assert_eq!(got["state"], "committed", "{got}");
        assert_eq!(self.listed(change_id)["saved_only"], expected);
    }

    /// A change that went to the desktop carries no `saved_only`.
    fn assert_applied_live(&self, change_id: &str) {
        let got = self
            .cli
            .result(catalog::CHANGES_GET, json!({"change_id": change_id}));
        assert!(got.get("saved_only").is_none(), "changes.get: {got}");
        assert!(self.listed(change_id).get("saved_only").is_none());
    }

    /// The change's summary as `changes.list` (the history list) gives it.
    fn listed(&self, change_id: &str) -> Value {
        self.cli
            .result(catalog::CHANGES_LIST, json!({"limit": 100}))["changes"]
            .as_array()
            .unwrap()
            .iter()
            .find(|summary| summary["change_id"] == json!(change_id))
            .unwrap_or_else(|| panic!("{change_id} is not listed"))
            .clone()
    }

    fn assert_reached_nobody(&self, record: &ChangeRecord, what: &str) {
        let reached = self.reached(&record.change_id);
        assert!(
            reached.is_empty(),
            "{what}: the change {} on the inactive profile {} reached {reached:?}; items {:?}",
            record.change_id,
            record.profile_id,
            record.items
        );
    }
}

fn settle(cli: &TestPeer, response: Value) -> ChangeRecord {
    if let Some(result) = response.get("result") {
        return record(result);
    }
    let change_id = response["error"]["data"]["change_id"].clone();
    assert!(change_id.is_string(), "{response}");
    record(&cli.result(catalog::CHANGES_GET, json!({"change_id": change_id})))
}

fn dock_config(projection: &ShellProjection) -> Value {
    projection
        .slots
        .iter()
        .find(|slot| slot.slot == "ui.dock")
        .map(|slot| slot.config.clone())
        .unwrap()
}

/// The ordinary edit: an entry config and an appearance token on 開發 while
/// 預設 is active. Preflight (with config_schema) still runs; the revision is
/// written; neither participant hears of it; the switch projects it.
#[test]
fn an_edit_of_an_inactive_profile_is_saved_and_reaches_no_participant() {
    let desk = desktop("inactive-edit");
    let active = desk.active_profile();
    let (active_head, _) = desk.head_of(&active);
    let other = desk.profile_named("開發");
    assert_ne!(other, active);
    let (other_head, other_document) = desk.head_of(&other);
    let dock = other_document.slot_entry("ui.dock").unwrap().clone();
    assert_eq!(dock.package, "ditto.dock.pill");
    assert_eq!(dock.config, json!({"position": "left"}));
    let shown = desk.live_shell();
    let prepares = desk.shell.lock().unwrap().prepares;

    // config_schema still applies to a Profile that is not active.
    let refused = desk.propose(json!({
        "profile_id": other, "base_revision": other_head,
        "ops": [{"op": "set_entry_config", "entry_id": dock.entry_id, "after": {"position": 3}}]}));
    assert_eq!(refused.state, ChangeState::Rejected, "{refused:?}");
    assert!(refused
        .reasons
        .iter()
        .any(|r| r.detail.get("why") == Some(&json!("config_schema_violation"))));

    let edit = desk.propose(json!({
        "profile_id": other, "base_revision": other_head,
        "ops": [
            {"op": "set_entry_config", "entry_id": dock.entry_id, "after": {"position": "bottom"}},
            {"op": "set_value", "path": "/appearance/tokens/accent", "after": "#123456"}]}));
    desk.assert_reached_nobody(&edit, "edit");
    desk.assert_saved_only(&edit.change_id, "開發");
    assert_eq!(desk.shell.lock().unwrap().prepares, prepares);
    assert_eq!(desk.live_shell(), shown, "the desktop changed");
    assert_eq!(edit.state, ChangeState::Committed, "{edit:?}");
    assert_eq!(edit.result, Some(ResultKind::Succeeded));
    assert!(edit.items.is_empty(), "{:?}", edit.items);
    assert_eq!(edit.confirmation, Confirmation::NotRequired);

    let (other_now, edited) = desk.head_of(&other);
    assert_eq!(edit.committed_revision.as_deref(), Some(other_now.as_str()));
    assert_ne!(other_now, other_head);
    assert_eq!(
        edited.entry(&dock.entry_id).unwrap().config,
        json!({"position": "bottom"})
    );
    assert_eq!(edited.appearance.tokens["accent"], "#123456");
    assert_eq!(desk.active_profile(), active);
    assert_eq!(desk.head_of(&active).0, active_head);

    // Switching to the edited Profile is what puts it on the desktop.
    let switched = desk.propose(json!({
        "base_revision": active_head,
        "ops": [{"op": "switch_profile", "to_profile": other}]}));
    assert_eq!(switched.state, ChangeState::Committed, "{switched:?}");
    assert_eq!(desk.reached(&switched.change_id), vec!["shell", "hostd"]);
    desk.assert_applied_live(&switched.change_id);
    let live = desk.live_shell();
    assert_eq!(dock_config(&live), json!({"position": "bottom"}));
    assert_eq!(live.appearance.tokens["accent"], "#123456");
    assert_eq!(desk.active_profile(), other);
}

/// A service entry's config on 簡報: hostd runs the active Profile's
/// services and must not be handed the other Profile's.
#[test]
fn a_service_edit_of_an_inactive_profile_does_not_reach_hostd() {
    let desk = desktop("inactive-service");
    let active = desk.active_profile();
    let other = desk.profile_named("簡報");
    assert_ne!(other, active);
    let (other_head, other_document) = desk.head_of(&other);
    let policy = other_document
        .slot_entry("svc.notification_policy")
        .unwrap()
        .clone();
    let running = desk.host.lock().unwrap().entries.clone();
    let edit = desk.propose(json!({
        "profile_id": other, "base_revision": other_head,
        "ops": [{"op": "set_entry_config", "entry_id": policy.entry_id,
                 "after": {"rules": {"focus": {"enabled": false, "allow": []}}}}]}));
    desk.assert_reached_nobody(&edit, "service edit");
    desk.assert_saved_only(&edit.change_id, "簡報");
    // The name is the Profile's name now, not a copy taken at commit.
    desk.cli.result(
        catalog::PROFILES_RENAME,
        json!({"profile_id": other, "name": "簡報（新）"}),
    );
    desk.assert_saved_only(&edit.change_id, "簡報（新）");
    assert_eq!(edit.state, ChangeState::Committed, "{edit:?}");
    assert_eq!(desk.host.lock().unwrap().entries, running);
    assert_eq!(
        desk.head_of(&other)
            .1
            .entry(&policy.entry_id)
            .unwrap()
            .config,
        json!({"rules": {"focus": {"enabled": false, "allow": []}}})
    );
    assert_eq!(desk.active_profile(), active);
}

/// Undo of a change on an inactive Profile, both ways undo works: the newest
/// change (back to its base) and an older one (inverse ops on the head).
#[test]
fn undo_on_an_inactive_profile_edits_only_its_document() {
    let desk = desktop("inactive-undo");
    let active = desk.active_profile();
    let other = desk.profile_named("開發");
    let (head0, document0) = desk.head_of(&other);
    let shown = desk.live_shell();
    let older = desk.propose(json!({
        "profile_id": other, "base_revision": head0,
        "ops": [{"op": "set_value", "path": "/appearance/tokens/accent", "after": "#0a0a0a"}]}));
    assert_eq!(older.state, ChangeState::Committed, "{older:?}");
    let (head1, _) = desk.head_of(&other);
    let newer = desk.propose(json!({
        "profile_id": other, "base_revision": head1,
        "ops": [{"op": "set_value", "path": "/avatar/hidden", "after": true}]}));
    assert_eq!(newer.state, ChangeState::Committed, "{newer:?}");

    // Older first: no overlapping path, so the inverse goes onto the head.
    let undo_older = desk.undo(&older.change_id);
    desk.assert_reached_nobody(&undo_older, "undo of the older change");
    desk.assert_saved_only(&undo_older.change_id, "開發");
    assert_eq!(undo_older.state, ChangeState::Committed, "{undo_older:?}");
    let (_, after_older) = desk.head_of(&other);
    assert_eq!(
        after_older.appearance.tokens["accent"],
        document0.appearance.tokens["accent"]
    );
    assert!(after_older.avatar.hidden);

    // The newest change on the Profile is now the undo above; undo it back.
    let undo_undo = desk.undo(&undo_older.change_id);
    desk.assert_reached_nobody(&undo_undo, "undo of the newest change");
    desk.assert_saved_only(&undo_undo.change_id, "開發");
    assert_eq!(undo_undo.state, ChangeState::Committed, "{undo_undo:?}");
    assert_eq!(
        desk.head_of(&other).1.appearance.tokens["accent"],
        "#0a0a0a"
    );

    assert_eq!(desk.live_shell(), shown, "the desktop changed");
    assert_eq!(desk.active_profile(), active);
}

/// A preview on the active Profile, then a switch before anyone confirms:
/// the timed revert lands on a Profile that is no longer on the desktop, so
/// it restores that Profile's document and leaves the desktop alone.
#[test]
fn a_timed_revert_after_switching_away_restores_only_the_document() {
    let desk = desktop("inactive-revert");
    let first = desk.active_profile();
    let (first_head, first_document) = desk.head_of(&first);
    let other = desk.profile_named("開發");
    let preview = desk.propose(json!({
        "base_revision": first_head, "mode": "preview",
        "ops": [{"op": "set_value", "path": "/appearance/tokens/accent", "after": "#777777"}]}));
    assert_eq!(preview.state, ChangeState::Committed, "{preview:?}");
    assert!(matches!(preview.confirmation, Confirmation::Pending { .. }));
    assert_eq!(desk.reached(&preview.change_id), vec!["shell"]);
    desk.assert_applied_live(&preview.change_id);

    let (pending_head, _) = desk.head_of(&first);
    let switched = desk.propose(json!({
        "base_revision": pending_head,
        "ops": [{"op": "switch_profile", "to_profile": other}]}));
    assert_eq!(switched.state, ChangeState::Committed, "{switched:?}");
    assert!(
        matches!(
            desk.get(&preview.change_id).confirmation,
            Confirmation::Pending { .. }
        ),
        "the countdown ended before the switch; the test needs a longer window"
    );
    let shown = desk.live_shell();

    let deadline = Instant::now() + Duration::from_secs(5);
    let reverted_by = loop {
        if let Confirmation::Reverted { by_change } = desk.get(&preview.change_id).confirmation {
            break by_change;
        }
        assert!(Instant::now() < deadline, "the preview was never reverted");
        thread::sleep(Duration::from_millis(50));
    };
    let revert = desk.get(&reverted_by);
    assert_eq!(
        revert.origin,
        ChangeOrigin::TimedRevert {
            reverts: preview.change_id.clone()
        }
    );
    desk.assert_reached_nobody(&revert, "timed revert");
    desk.assert_saved_only(&revert.change_id, "預設");
    assert_eq!(revert.state, ChangeState::Committed, "{revert:?}");
    assert_eq!(desk.live_shell(), shown, "the desktop changed");
    assert_eq!(desk.active_profile(), other);
    assert_eq!(
        desk.head_of(&first).1.appearance.tokens["accent"],
        first_document.appearance.tokens["accent"]
    );
}

/// Rescue restore naming a Profile that is not active puts its last-known-good
/// back as its head and leaves the running desktop as it is.
#[test]
fn rescue_restore_of_an_inactive_profile_restores_only_the_document() {
    let desk = desktop("inactive-rescue");
    let active = desk.active_profile();
    let (active_head, _) = desk.head_of(&active);
    let other = desk.profile_named("開發");
    let (good_head, good) = desk.head_of(&other);
    // 開發 has run well at good_head; since then its head moved on.
    let mut broken = good.clone();
    broken
        .appearance
        .tokens
        .insert("accent".into(), "#bad000".into());
    let (profile, good_revision) = (other.clone(), good_head.clone());
    desk.harness
        .core
        .coordinate(Duration::from_secs(10), move |co| {
            co.store()
                .write(|tx| {
                    profiles::set_last_known_good(tx, &profile, &good_revision)?;
                    let revision = profiles::insert_revision(
                        tx,
                        &profile,
                        Some(&good_revision),
                        &broken,
                        &RevisionOrigin::Import,
                        None,
                    )?;
                    profiles::set_head(tx, &profile, &revision.revision_id)
                })
                .unwrap()
        })
        .unwrap();
    assert_eq!(
        desk.head_of(&other).1.appearance.tokens["accent"],
        "#bad000"
    );
    let shown = desk.live_shell();

    let profile = other.clone();
    let restored = desk
        .harness
        .core
        .coordinate(Duration::from_secs(20), move |co| {
            co.rescue_restore(Some(&profile), "cli:rescue", None)
        })
        .unwrap()
        .unwrap();
    desk.assert_reached_nobody(&restored, "rescue restore");
    desk.assert_saved_only(&restored.change_id, "開發");
    assert_eq!(restored.state, ChangeState::Committed, "{restored:?}");
    assert_eq!(restored.origin, ChangeOrigin::Rescue);
    assert_eq!(desk.head_of(&other).1, good);
    assert_eq!(desk.live_shell(), shown, "the desktop changed");
    assert_eq!(desk.active_profile(), active);
    assert_eq!(desk.head_of(&active).0, active_head);
}

/// Boot recovery of a change to an inactive Profile that a crash left in
/// `applying`: no participant had been asked anything, so none is waited
/// for or read back; the revision is written as the change intended.
#[test]
fn recovery_finishes_an_interrupted_change_to_an_inactive_profile_without_participants() {
    let root = root("inactive-recovery");
    let base = plain_document("#101010");
    let target = plain_document("#202020");
    let seeded = Arc::new(Mutex::new(None));
    let recorded = Arc::clone(&seeded);
    let (stored_base, stored_target) = (base.clone(), target.clone());
    seed_store(&root, &base, &base, move |tx, _, _, _| {
        let (other, head) = profiles::create(
            tx,
            "其他",
            &stored_base,
            &RevisionOrigin::Create {
                from: "default".into(),
            },
        )?;
        let change = interrupted_change(
            tx,
            &other.profile_id,
            &head.revision_id,
            &stored_target,
            ChangeState::Applying,
            "k-inactive",
        )?;
        *recorded.lock().unwrap() = Some((other.profile_id, change));
        Ok(())
    });
    // No Shell and no hostd: a change on the active Profile would end
    // `unknown` here (recovery_without_the_participant_is_unknown_...).
    let core = start_without_waiting(&root, false);
    core.coordinate(Duration::from_secs(15), |_| ()).unwrap();
    let cli = TestPeer::connect(&core, "dittoctl", None);
    let (other, change_id) = seeded.lock().unwrap().clone().unwrap();
    let change = record(&cli.result(catalog::CHANGES_GET, json!({"change_id": change_id})));
    assert_eq!(change.state, ChangeState::Committed, "{change:?}");
    assert!(change.items.is_empty(), "{:?}", change.items);
    assert!(change.recovered_at.is_some());
    let raw = cli.result(catalog::CHANGES_GET, json!({"change_id": change_id}));
    assert_eq!(
        raw["saved_only"],
        json!({"reason": "inactive_profile", "profile_name": "其他"}),
        "{raw}"
    );
    let got = cli.result(catalog::PROFILES_GET, json!({"profile_id": other}));
    assert_eq!(got["document"]["appearance"]["tokens"]["accent"], "#202020");
    assert_eq!(
        got["profile"]["head_revision"].as_str(),
        change.committed_revision.as_deref()
    );
    // The active Profile is untouched.
    assert_eq!(document(&cli)["appearance"]["tokens"]["accent"], "#101010");
    drop(core);
    let _ = std::fs::remove_dir_all(&root);
}
