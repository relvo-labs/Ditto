//! #175: rows a pre-#171 build could leave. Seed them directly, before Core
//! starts, without proposing a new preview or passing the current delete guard.
use super::*;
use ditto_protocol::{
    change::{ChangeCard, ChangeMode, ChangeOrigin, Confirmation, HotSwapLevel},
    profile::RevisionOrigin,
};
use ditto_store::{changes, profiles, Store, WriterLock};

fn legacy_preview(label: &str, deadline: String, deleted: bool) -> (Harness, String) {
    let root = root(label);
    let paths = Paths::under(&root.join("store"));
    let change_id = {
        let lock = WriterLock::acquire(&paths.lock()).unwrap();
        let (mut store, _) = Store::open_writer(&paths, &lock).unwrap();
        store.write(|tx| {
            let document = crate::defaults::empty_document();
            let (active, _) = profiles::create(tx, "current", &document, &RevisionOrigin::Import)?;
            profiles::set_active_profile(tx, &active.profile_id)?;
            let (profile, base) = profiles::create(tx, "legacy", &document, &RevisionOrigin::Import)?;
            let card = ChangeCard { kind: "appearance".into(), title_key: "change.title.appearance".into(),
                title_args: Default::default(), items: vec![], footnote_key: None };
            let stored = changes::insert(tx, &changes::NewChange {
                profile_id: &profile.profile_id, base_revision: &base.revision_id,
                ops: &[], mode: ChangeMode::Preview, origin: &ChangeOrigin::Cli, subject: "cli",
                idempotency_key: None, request_operation_id: None, card: &card,
                hot_swap_level: HotSwapLevel::Instant,
            })?;
            let id = stored.record.change_id;
            let mut target = document;
            target.appearance.tokens.insert("accent".into(), "#777777".into());
            let revision = profiles::insert_revision(tx, &profile.profile_id, Some(&base.revision_id),
                &target, &RevisionOrigin::Change { change_id: id.clone() }, Some(&id))?;
            profiles::set_head(tx, &profile.profile_id, &revision.revision_id)?;
            changes::set_committed_revision(tx, &id, &revision.revision_id)?;
            for (from, to) in [(ChangeState::Draft, ChangeState::Validated),
                (ChangeState::Validated, ChangeState::Prepared), (ChangeState::Prepared, ChangeState::Applying),
                (ChangeState::Applying, ChangeState::Verifying), (ChangeState::Verifying, ChangeState::Committed)] {
                changes::transition(tx, &id, from, to)?;
            }
            changes::set_confirmation(tx, &id, &Confirmation::Pending { deadline })?;
            profiles::set_pending_confirmation(tx, &revision.revision_id, true)?;
            if deleted { profiles::soft_delete(tx, &profile.profile_id)?; }
            Ok(id)
        }).unwrap()
    };
    let core = start_at(&root, false);
    (Harness { core, root }, change_id)
}

fn read(harness: &Harness, id: &str) -> (ChangeRecord, bool) {
    let id = id.to_string();
    harness.core.coordinate(Duration::from_secs(10), move |co| {
        let connection = co.store_ref().connection();
        let record = changes::get(connection, &id).unwrap().record;
        let revision = profiles::revision(connection, record.committed_revision.as_ref().unwrap()).unwrap().0;
        (record, revision.pending_confirmation)
    }).unwrap()
}

fn assert_settled(harness: &Harness, id: &str) {
    let (record, pending) = read(harness, id);
    // The countdown ended without reverting anything.
    assert_eq!(serde_json::to_value(&record.confirmation).unwrap()["state"], "ended");
    assert!(!pending);
    assert!(record.profile_deleted);
}

#[test]
fn deleted_preview_cancel_settles_legacy_rows() {
    let deadline = ditto_store::time::format_unix_millis(ditto_store::time::unix_millis_now() + 600_000);
    let (harness, id) = legacy_preview("deleted-preview-cancel", deadline, true);
    let cancel_id = id.clone();
    harness.core.coordinate(Duration::from_secs(10), move |co| co.cancel(&cancel_id).unwrap()).unwrap();
    assert_settled(&harness, &id);
}

#[test]
fn deleted_preview_boot_settles_an_elapsed_deadline() {
    let (harness, id) = legacy_preview("deleted-preview-overdue", "2000-01-01T00:00:00.000Z".into(), true);
    assert_settled(&harness, &id);
}

#[test]
fn deleted_preview_boot_rearms_a_future_deadline() {
    let deadline = ditto_store::time::format_unix_millis(ditto_store::time::unix_millis_now() + 1500);
    let (harness, id) = legacy_preview("deleted-preview-rearm", deadline, true);
    assert!(matches!(read(&harness, &id).0.confirmation, Confirmation::Pending { .. }));
    thread::sleep(Duration::from_secs(2));
    assert_settled(&harness, &id);
}
