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
    wait_for_host_boot_sync(&host);
    Desktop {
        harness,
        cli,
        shell,
        host,
        _peers: vec![shell_peer, host_peer],
    }
}

/// Core pushes hostd's boot sync when hostd reports ready (`host_ready`),
/// as coordinator work queued after `host.hello` has answered, so it can
/// land after `fake_host` returns. Wait until hostd has prepared that sync
/// and committed what it prepared, or a test that snapshots what hostd
/// runs races it.
fn wait_for_host_boot_sync(host: &Arc<Mutex<HostState>>) {
    let synced = || {
        let host = host.lock().unwrap();
        host.candidates
            .iter()
            .any(|(change_id, entries)| change_id.starts_with("boot-") && host.entries == *entries)
    };
    let deadline = Instant::now() + Duration::from_secs(5);
    while !synced() && Instant::now() < deadline {
        thread::sleep(Duration::from_millis(20));
    }
    assert!(synced(), "the boot sync never reached the fake hostd");
    assert!(
        !host.lock().unwrap().entries.is_empty(),
        "the active Profile's services were not committed to the fake hostd"
    );
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

/// The history list as `changes.list` gives it, every Profile.
fn listed_ids(desk: &Desktop) -> Vec<Value> {
    desk.cli
        .result(catalog::CHANGES_LIST, json!({"limit": 100}))["changes"]
        .as_array()
        .unwrap()
        .iter()
        .map(|summary| summary["change_id"].clone())
        .collect()
}

/// What the fake participants have been asked so far.
fn participant_calls(desk: &Desktop) -> (u32, usize, usize, Vec<Value>) {
    let shell = desk.shell.lock().unwrap();
    let host = desk.host.lock().unwrap();
    (
        shell.prepares,
        shell.candidates.len(),
        host.candidates.len(),
        host.entries.clone(),
    )
}

/// Undo of a change whose Profile is deleted: refused as `not_found` with a
/// message that says why (protocol 0.2 §8.6), before any record is written
/// or any participant is asked.
fn assert_undo_refused_as_deleted(desk: &Desktop, change_id: &str) {
    let listed = listed_ids(desk);
    let shown = desk.live_shell();
    let asked = participant_calls(desk);
    let refused = desk
        .cli
        .call(catalog::CHANGES_UNDO, json!({"change_id": change_id}));
    assert_eq!(refused["error"]["name"], "not_found", "{refused}");
    let message = refused["error"]["message"].as_str().unwrap();
    assert!(
        message.contains("deleted") && message.contains("cannot be undone"),
        "{refused}"
    );
    assert_eq!(listed_ids(desk), listed, "undo wrote a change");
    assert_eq!(desk.live_shell(), shown, "the desktop changed");
    assert_eq!(participant_calls(desk), asked, "a participant was asked");
}

/// `changes.get` and `changes.list` both say the change's Profile is
/// deleted, at the record level (#171).
fn assert_profile_deleted(desk: &Desktop, change_id: &str) {
    let got = desk
        .cli
        .result(catalog::CHANGES_GET, json!({"change_id": change_id}));
    assert_eq!(got["profile_deleted"], true, "changes.get: {got}");
    let listed = desk.listed(change_id);
    assert_eq!(listed["profile_deleted"], true, "changes.list: {listed}");
}

/// #171: a saved_only change, then its Profile is deleted. The record still
/// reads (soft delete keeps the name) and now says the Profile is deleted,
/// in `changes.get` and in the history list; switching to it is impossible,
/// and undo is a clear refusal, not an internal error. An undo sent before
/// the delete and replayed with its idempotency key still returns the
/// record it made.
#[test]
fn a_saved_only_change_whose_profile_is_deleted_says_so_and_cannot_be_undone() {
    let desk = desktop("inactive-deleted");
    let active = desk.active_profile();
    let other = desk.profile_named("開發");
    let (head, _) = desk.head_of(&other);
    let edit = desk.propose(json!({
        "profile_id": other, "base_revision": head,
        "ops": [{"op": "set_value", "path": "/appearance/tokens/accent", "after": "#123456"}]}));
    assert_eq!(edit.state, ChangeState::Committed, "{edit:?}");
    let (head, _) = desk.head_of(&other);
    let later = desk.propose(json!({
        "profile_id": other, "base_revision": head,
        "ops": [{"op": "set_value", "path": "/avatar/hidden", "after": true}]}));
    assert_eq!(later.state, ChangeState::Committed, "{later:?}");
    let undone = desk.cli.result(
        catalog::CHANGES_UNDO,
        json!({"change_id": later.change_id, "idempotency_key": "undo-171"}),
    );
    assert_eq!(undone["state"], "committed", "{undone}");
    // While the Profile exists the field is left out.
    desk.assert_saved_only(&edit.change_id, "開發");
    for change_id in [&edit.change_id, &later.change_id] {
        let got = desk
            .cli
            .result(catalog::CHANGES_GET, json!({"change_id": change_id}));
        assert!(got.get("profile_deleted").is_none(), "{got}");
        assert!(desk.listed(change_id).get("profile_deleted").is_none());
    }

    desk.cli
        .result(catalog::PROFILES_DELETE, json!({"profile_id": other}));
    // saved_only reads as before; the deletion is said beside it.
    desk.assert_saved_only(&edit.change_id, "開發");
    assert_profile_deleted(&desk, &edit.change_id);
    let got = desk
        .cli
        .result(catalog::CHANGES_GET, json!({"change_id": edit.change_id}));
    assert_eq!(got["state"], "committed", "{got}");
    assert_eq!(got["result"], "succeeded", "{got}");

    assert_undo_refused_as_deleted(&desk, &edit.change_id);
    // The replayed undo returns the record it made before the delete.
    let asked = participant_calls(&desk);
    let replayed = desk.cli.result(
        catalog::CHANGES_UNDO,
        json!({"change_id": later.change_id, "idempotency_key": "undo-171"}),
    );
    assert_eq!(replayed["change_id"], undone["change_id"], "{replayed}");
    assert_eq!(replayed["state"], "committed", "{replayed}");
    assert_eq!(replayed["profile_deleted"], true, "{replayed}");
    assert_eq!(participant_calls(&desk), asked, "a participant was asked");
    assert_eq!(desk.active_profile(), active);
}

/// The same for a change that was applied to the desktop and whose Profile
/// was deleted after switching away: no `saved_only` here, and the record
/// still says the Profile is deleted, so no surface offers its undo.
#[test]
fn an_applied_change_on_a_deleted_profile_says_so_and_cannot_be_undone() {
    let desk = desktop("deleted-applied");
    let first = desk.active_profile();
    let (first_head, _) = desk.head_of(&first);
    let applied = desk.propose(json!({
        "base_revision": first_head,
        "ops": [{"op": "set_value", "path": "/appearance/tokens/accent", "after": "#654321"}]}));
    assert_eq!(applied.state, ChangeState::Committed, "{applied:?}");
    desk.assert_applied_live(&applied.change_id);
    let other = desk.profile_named("開發");
    let (now, _) = desk.head_of(&first);
    let switched = desk.propose(json!({
        "base_revision": now,
        "ops": [{"op": "switch_profile", "to_profile": other}]}));
    assert_eq!(switched.state, ChangeState::Committed, "{switched:?}");
    desk.cli
        .result(catalog::PROFILES_DELETE, json!({"profile_id": first}));
    desk.assert_applied_live(&applied.change_id);
    assert_profile_deleted(&desk, &applied.change_id);
    // The switch is recorded under the Profile it left.
    assert_profile_deleted(&desk, &switched.change_id);

    assert_undo_refused_as_deleted(&desk, &applied.change_id);
    // Undoing the switch would switch back to the deleted Profile.
    assert_undo_refused_as_deleted(&desk, &switched.change_id);
    assert_eq!(desk.active_profile(), other);
}

/// `change_updated` and `resync_required` notifications the CLI has seen
/// on the `changes` subscription `subscription`, as payloads.
fn change_events(desk: &Desktop, subscription: &Value) -> Vec<Value> {
    desk.cli
        .events
        .lock()
        .unwrap()
        .iter()
        .filter(|event| event["params"]["subscription_id"] == *subscription)
        .map(|event| event["params"]["payload"].clone())
        .filter(|payload| {
            payload["type"] == "change_updated" || payload["type"] == "resync_required"
        })
        .collect()
}

/// A subscription to the `changes` topic only; its id.
fn subscribe_to_changes(desk: &Desktop) -> Value {
    let subscribed = desk
        .cli
        .result(catalog::EVENTS_SUBSCRIBE, json!({"topics": ["changes"]}));
    assert!(subscribed["subscription_id"].is_string(), "{subscribed}");
    subscribed["subscription_id"].clone()
}

/// #171: views that already hold a change of the deleted Profile (a history
/// row, an expanded card, a chat card) learn of it from Core: deleting the
/// Profile publishes `change_updated` again for each committed change of
/// that Profile, read the same way `changes.get` reads it, so with
/// `profile_deleted`. Nothing is published for other Profiles, nor for a
/// change of the Profile that did not commit (it promises nothing).
#[test]
fn deleting_a_profile_publishes_its_committed_changes_again() {
    let desk = desktop("deleted-events");
    let other = desk.profile_named("開發");
    let third = desk.profile_named("簡報");
    let edit = |profile: &str, accent: &str| {
        let (head, _) = desk.head_of(profile);
        let record = desk.propose(json!({
            "profile_id": profile, "base_revision": head,
            "ops": [{"op": "set_value", "path": "/appearance/tokens/accent", "after": accent}]}));
        assert_eq!(record.state, ChangeState::Committed, "{record:?}");
        record.change_id
    };
    let first = edit(&other, "#111111");
    let second = edit(&other, "#222222");
    let elsewhere = edit(&third, "#333333");
    let (head, document) = desk.head_of(&other);
    let dock = document.slot_entry("ui.dock").unwrap().entry_id.clone();
    let refused = desk.propose(json!({
        "profile_id": other, "base_revision": head,
        "ops": [{"op": "set_entry_config", "entry_id": dock, "after": {"position": 3}}]}));
    assert_eq!(refused.state, ChangeState::Rejected, "{refused:?}");

    let subscription = subscribe_to_changes(&desk);
    desk.cli.events.lock().unwrap().clear();
    desk.cli
        .result(catalog::PROFILES_DELETE, json!({"profile_id": other}));
    let deadline = Instant::now() + Duration::from_secs(5);
    while change_events(&desk, &subscription).len() < 2 && Instant::now() < deadline {
        thread::sleep(Duration::from_millis(20));
    }
    // Anything published late would land now.
    thread::sleep(Duration::from_millis(200));
    let events = change_events(&desk, &subscription);
    let mut published: Vec<String> = events
        .iter()
        .map(|payload| {
            assert_eq!(payload["type"], "change_updated", "{payload}");
            assert_eq!(payload["change"]["profile_deleted"], true, "{payload}");
            assert_eq!(payload["change"]["profile_id"], json!(other), "{payload}");
            payload["change"]["change_id"].as_str().unwrap().to_string()
        })
        .collect();
    published.sort();
    let mut expected = vec![first.clone(), second.clone()];
    expected.sort();
    assert_eq!(published, expected, "{events:?}");
    assert!(!published.contains(&elsewhere));
    assert!(!published.contains(&refused.change_id));
    // Each published summary is what the history list now reads.
    for payload in &events {
        let id = payload["change"]["change_id"].as_str().unwrap();
        let mut listed = desk.listed(id);
        let mut sent = payload["change"].clone();
        listed.as_object_mut().unwrap().remove("_meta");
        sent.as_object_mut().unwrap().remove("_meta");
        assert_eq!(sent, listed);
    }
}

/// Past the bound on how many changes a delete publishes again, Core asks
/// every `changes` subscriber to read again (`resync_required`, reason
/// `profile_deleted`) instead, so no view keeps a stale record. The bound is
/// lowered here to 1 so two changes cross it.
#[test]
fn deleting_a_profile_with_more_changes_than_the_bound_asks_views_to_read_again() {
    let desk = desktop("deleted-resync");
    let other = desk.profile_named("開發");
    for accent in ["#111111", "#222222"] {
        let (head, _) = desk.head_of(&other);
        let record = desk.propose(json!({
            "profile_id": other, "base_revision": head,
            "ops": [{"op": "set_value", "path": "/appearance/tokens/accent", "after": accent}]}));
        assert_eq!(record.state, ChangeState::Committed, "{record:?}");
    }
    let subscription = subscribe_to_changes(&desk);
    desk.cli.events.lock().unwrap().clear();
    let profile = other.clone();
    desk.harness
        .core
        .coordinate(Duration::from_secs(10), move |co| {
            co.delete_profile_refreshing(&profile, 1)
        })
        .unwrap()
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    while change_events(&desk, &subscription).is_empty() && Instant::now() < deadline {
        thread::sleep(Duration::from_millis(20));
    }
    thread::sleep(Duration::from_millis(200));
    let events = change_events(&desk, &subscription);
    assert_eq!(
        events,
        vec![json!({"type": "resync_required", "reason": "profile_deleted"})],
        "{events:?}"
    );
    let gone = desk
        .cli
        .call(catalog::PROFILES_GET, json!({"profile_id": other}));
    assert_eq!(gone["error"]["name"], "not_found", "{gone}");
}

/// A preview on `first` (the active Profile), then a switch to 開發 before
/// anyone keeps it: `first` is no longer active, and its preview is still
/// counting down. Returns (first, 開發, the preview's change id).
fn preview_then_switch_away(desk: &Desktop) -> (String, String, String) {
    let first = desk.active_profile();
    let (head, _) = desk.head_of(&first);
    let other = desk.profile_named("開發");
    let preview = desk.propose(json!({
        "base_revision": head, "mode": "preview",
        "ops": [{"op": "set_value", "path": "/appearance/tokens/accent", "after": "#777777"}]}));
    assert_eq!(preview.state, ChangeState::Committed, "{preview:?}");
    assert!(matches!(preview.confirmation, Confirmation::Pending { .. }));
    let (pending_head, _) = desk.head_of(&first);
    let switched = desk.propose(json!({
        "base_revision": pending_head,
        "ops": [{"op": "switch_profile", "to_profile": other}]}));
    assert_eq!(switched.state, ChangeState::Committed, "{switched:?}");
    (first, other, preview.change_id)
}

/// Delete `profile` while its preview counts down: refused as `conflict`
/// (`change_in_progress`) before anything is deleted or published.
fn assert_delete_refused_while_trying_out(desk: &Desktop, profile: &str, preview: &str) {
    let subscription = subscribe_to_changes(desk);
    desk.cli.events.lock().unwrap().clear();
    let refused = desk
        .cli
        .call(catalog::PROFILES_DELETE, json!({"profile_id": profile}));
    assert_eq!(refused["error"]["name"], "conflict", "{refused}");
    assert_eq!(
        refused["error"]["data"]["reason"], "change_in_progress",
        "{refused}"
    );
    let message = refused["error"]["message"].as_str().unwrap();
    assert!(
        message.contains("kept or reverted") && message.contains(preview),
        "{refused}"
    );
    // Nothing was deleted.
    let listed = desk.cli.result(catalog::PROFILES_LIST, json!({}));
    assert!(
        listed["profiles"]
            .as_array()
            .unwrap()
            .iter()
            .any(|p| p["profile_id"] == json!(profile)),
        "{listed}"
    );
    let got = desk
        .cli
        .result(catalog::CHANGES_GET, json!({"change_id": preview}));
    assert!(got.get("profile_deleted").is_none(), "{got}");
    // No refresh burst: nothing published says the Profile is deleted.
    thread::sleep(Duration::from_millis(100));
    for payload in change_events(desk, &subscription) {
        assert_ne!(payload["change"]["profile_deleted"], true, "{payload}");
    }
}

/// #171 R2: a preview still counting down on a Profile that is no longer
/// active would be reverted in that Profile's document; a deleted Profile
/// has none, and the countdown would be left pending for good. So the
/// delete is refused until the preview is settled; keeping it settles it,
/// and the delete then goes through.
#[test]
fn deleting_a_profile_whose_preview_counts_down_is_refused_until_it_is_kept() {
    let desk = desktop("deleted-preview-kept");
    let (first, other, preview) = preview_then_switch_away(&desk);
    assert_delete_refused_while_trying_out(&desk, &first, &preview);
    let kept = desk
        .cli
        .call(catalog::CHANGES_CONFIRM, json!({"change_id": preview}));
    assert_eq!(
        kept["result"]["confirmation"]["state"], "confirmed",
        "the countdown ended before the preview was kept; the test needs a longer window: {kept}"
    );
    desk.cli
        .result(catalog::PROFILES_DELETE, json!({"profile_id": first}));
    assert_profile_deleted(&desk, &preview);
    assert_eq!(desk.active_profile(), other);
}

/// The same, settled by the countdown: the timed revert runs in the still
/// existing Profile, then the delete goes through.
#[test]
fn deleting_a_profile_whose_preview_counts_down_is_refused_until_it_reverts() {
    let desk = desktop("deleted-preview-reverted");
    let (first, other, preview) = preview_then_switch_away(&desk);
    assert_delete_refused_while_trying_out(&desk, &first, &preview);
    let deadline = Instant::now() + Duration::from_secs(5);
    let reverted_by = loop {
        if let Confirmation::Reverted { by_change } = desk.get(&preview).confirmation {
            break by_change;
        }
        assert!(Instant::now() < deadline, "the preview was never reverted");
        thread::sleep(Duration::from_millis(50));
    };
    assert_eq!(desk.get(&reverted_by).state, ChangeState::Committed);
    desk.cli
        .result(catalog::PROFILES_DELETE, json!({"profile_id": first}));
    assert_profile_deleted(&desk, &preview);
    assert_profile_deleted(&desk, &reverted_by);
    assert_eq!(desk.active_profile(), other);
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
