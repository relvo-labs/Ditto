//! Official development capability Provider. Only Core writes artifacts,
//! installs validated bundles, and proposes their activation transaction.
use crate::{
    coordinator::Proposal,
    core::Core,
    error::CoreError,
    router::{self, Call, Caller, Handled},
};
use ditto_protocol::{
    catalog,
    change::{ChangeMode, ChangeOp, ChangeOrigin, NewEntry},
    generation::*,
    profile::HostKind,
    rpc::CoreMode,
    services::{Job, JobState},
    UnavailableReason,
};
use ditto_store::{generated, jobs, packages, StoreError};
use serde_json::{json, Value};
use std::{fs, os::unix::fs::PermissionsExt, sync::Arc};

pub(crate) fn recheck_authorization(
    core: &Core,
    caller: &Caller,
    contract: &catalog::CapabilityContract,
    params: &serde_json::Map<String, Value>,
    approved_once: bool,
) -> Result<(), CoreError> {
    if core.session_locked() {
        return Err(CoreError::unavailable(
            UnavailableReason::SessionLocked,
            "the session locked before the generated operation was accepted",
        ));
    }
    if approved_once {
        Ok(())
    } else {
        router::authorize(core, caller, contract, params)
    }
}

fn mutate<T: Send + 'static>(
    core: &Arc<Core>,
    caller: &Caller,
    call: &Call<'_>,
    work: impl FnOnce(&mut crate::coordinator::Coordinator) -> ditto_store::StoreResult<T>
        + Send
        + 'static,
) -> Result<T, CoreError> {
    let authority = Arc::clone(core);
    let caller = caller.clone();
    let contract = call.contract.clone();
    let params = call.params.clone();
    let approved_once = call.approved_once;
    router::coordinate(core, call, move |coordinator| {
        recheck_authorization(&authority, &caller, &contract, &params, approved_once)?;
        work(coordinator).map_err(CoreError::from)
    })?
}

pub fn available(core: &Core, preview: bool) -> bool {
    let bin = std::env::current_exe()
        .ok()
        .and_then(|p| p.parent().map(|p| p.to_owned()));
    core.mode == CoreMode::Normal
        && core.jobs.ready()
        && bin.is_some_and(|p| {
            [
                "ditto-generation-host",
                "ditto-generation-runner",
                "ditto-generation-runner.json",
                "ditto-confine",
            ]
            .iter()
            .all(|s| p.join(s).is_file())
        })
        && (!preview || std::env::var_os("WAYLAND_DISPLAY").is_some())
}
pub fn dispatch(core: &Arc<Core>, caller: &Caller, call: &Call<'_>) -> Handled {
    match call.contract.capability_id {
        catalog::DEVELOPMENT_GET => {
            let input: ArtifactInput = call.input()?;
            Ok((
                json!(core.read(|c| generated::get(c, &input.artifact_id))?),
                false,
            ))
        }
        catalog::DEVELOPMENT_LIST => {
            let _: ditto_protocol::Empty = call.input()?;
            Ok((
                json!(ArtifactsOutput {
                    artifacts: core.read(generated::list)?
                }),
                false,
            ))
        }
        catalog::DEVELOPMENT_CREATE => {
            let input: GenerateInput = call.input()?;
            let origin = router::origin_for(core, caller, call, Some("plugin-development".into()))?;
            let turn_id = match origin {
                ChangeOrigin::Agent { turn_id, .. } => Some(turn_id),
                _ => None,
            };
            let source = GenerationOrigin {
                request_summary: input.request_summary.clone(),
                turn_id,
                model: None,
            };
            let a = mutate(core, caller, call, move |c| {
                c.store().write(|tx| generated::create(tx, &input, source))
            })?;
            Ok((
                json!(core.read(|c| generated::get(c, &a.artifact_id))?),
                true,
            ))
        }
        catalog::DEVELOPMENT_VALIDATE | catalog::DEVELOPMENT_PREVIEW => submit(core, caller, call),
        catalog::DEVELOPMENT_PUBLISH => {
            let input: ArtifactInput = call.input()?;
            let a = core.read(|c| generated::get(c, &input.artifact_id))?;
            if generated::approved(&a) {
                return Ok((json!(a), true));
            }
            if a.state != ArtifactState::Validated
                || !generated::integrity(&a)
                || !a
                    .validation
                    .as_ref()
                    .is_some_and(|v| v.passed(&a.bundle_sha256))
            {
                return Err(CoreError::invalid(
                    "the artifact has not passed full isolated validation",
                ));
            }
            let paths = core.paths.clone();
            let a = mutate(core, caller, call, move |c| {
                let unpacked = materialize(&paths, &a)?;
                c.store().write(|tx| {
                    let mut current = generated::get(tx, &a.artifact_id)?;
                    if current.validation != a.validation
                        || current.bundle_sha256 != a.bundle_sha256
                    {
                        return Err(StoreError::Conflict(
                            "artifact changed while publishing".into(),
                        ));
                    }
                    packages::insert(tx, &unpacked, "generated", None)?;
                    current.state = ArtifactState::Published;
                    generated::save(tx, &current)?;
                    Ok(current)
                })
            })?;
            Ok((json!(a), true))
        }
        catalog::DEVELOPMENT_ACTIVATE => activate(core, caller, call),
        catalog::DEVELOPMENT_DATA_GET => {
            let input: ArtifactInput = call.input()?;
            Ok((
                json!(core.read(|c| {
                    let a = generated::get(c, &input.artifact_id)?;
                    generated::data_get(c, &a)
                })?),
                false,
            ))
        }
        catalog::DEVELOPMENT_DATA_WRITE => {
            let input: GeneratedDataInput = call.input()?;
            let value = mutate(core, caller, call, move |c| {
                c.store().write(|tx| {
                    let a = generated::get(tx, &input.artifact_id)?;
                    if !generated::approved(&a) || a.state != ArtifactState::Active {
                        return Err(StoreError::Invalid(
                            "plugin data owner is not enabled".into(),
                        ));
                    }
                    let profile = ditto_store::profiles::active_profile(tx)?
                        .ok_or_else(|| StoreError::NotFound("active profile".into()))?;
                    let (_, _, document) = ditto_store::profiles::head_document(tx, &profile)?;
                    if !document.entries.iter().any(|entry| {
                        !entry.disabled
                            && entry.package == a.description.plugin_id
                            && entry.version == a.description.version
                    }) {
                        return Err(StoreError::Conflict(
                            "plugin data owner is not in the active composition".into(),
                        ));
                    }
                    generated::data_write(tx, &a, &input)
                })
            })?;
            Ok((json!(value), true))
        }
        _ => Err(CoreError::invalid("unknown development operation")),
    }
}
fn submit(core: &Arc<Core>, caller: &Caller, call: &Call<'_>) -> Handled {
    let input: GenerationJobInput = call.input()?;
    let preview = call.contract.capability_id == catalog::DEVELOPMENT_PREVIEW;
    if !available(core, preview) {
        return Err(CoreError::unavailable(
            UnavailableReason::SystemUnavailable,
            "isolated generation host is unavailable; candidate remains inspectable",
        ));
    }
    if input.idempotency_key.is_empty() || input.idempotency_key.len() > 128 {
        return Err(CoreError::invalid("invalid generation job key"));
    }
    let owner = caller.subject.0.clone();
    let root = core.paths.cache.join("generated-validation");
    let job = mutate(core, caller, call, move |c| {
        c.store()
            .write(|tx| enqueue(tx, &input, preview, &owner, &root))
    })?;
    core.jobs.wake();
    Ok((json!(job), true))
}
// Invoked only inside submit's serialized store write. Keep budget admission,
// job insertion and artifact reservation atomic; previews consume no repair.
fn enqueue(
    tx: &rusqlite::Connection,
    input: &GenerationJobInput,
    preview: bool,
    owner: &str,
    root: &std::path::Path,
) -> Result<Job, StoreError> {
    let mut a = generated::get(tx, &input.artifact_id)?;
    let kind = if preview {
        "generation.preview"
    } else {
        "generation.validate"
    };
    let key = format!("{kind}:{}:{}", a.artifact_id, input.idempotency_key);
    if let Some(job) = jobs::by_idempotency_key(tx, &key)? {
        return Ok(job);
    }
    if preview
        && !a
            .validation
            .as_ref()
            .is_some_and(|v| v.passed(&a.bundle_sha256))
    {
        return Err(StoreError::Invalid(
            "preview requires all validation stages".into(),
        ));
    }
    if !preview {
        generated::check_turn_budget(tx, &a.origin)?;
        if let Some(job) = a
            .validation_job_id
            .as_ref()
            .and_then(|id| jobs::get(tx, id).ok())
        {
            if job.idempotency_key.as_deref()
                == Some(&format!(
                    "{kind}:{}:{}",
                    a.artifact_id, input.idempotency_key
                ))
            {
                return Ok(job);
            }
            if matches!(
                job.state,
                JobState::Queued | JobState::Running | JobState::Cancelling
            ) {
                return Err(StoreError::Conflict(
                    "artifact validation already running".into(),
                ));
            }
        }
        if !matches!(
            a.state,
            ArtifactState::Candidate | ArtifactState::InspectOnly
        ) || a.repair.stopped
        {
            return Err(StoreError::Conflict(
                "create a repaired new version before validating again".into(),
            ));
        }
    }
    if !generated::integrity(&a) {
        return Err(StoreError::Invalid("candidate integrity mismatch".into()));
    }
    // Worker parameters need source and integrity, never conversation text.
    let mut candidate = a.clone();
    candidate.origin = GenerationOrigin {
        request_summary: "isolated template validation".into(),
        turn_id: None,
        model: None,
    };
    // Private Core admission metadata is immutable per job, and never
    // copied from caller input or from conversation text.
    let params =
        json!({"artifact":candidate,"work_root":root,"generation_turn_id":a.origin.turn_id});
    let job = jobs::enqueue(
        tx,
        kind,
        owner,
        &params,
        &key,
        if preview { 60000 } else { 45000 },
    )?;
    if preview {
        a.previews.push(PreviewRecord {
            job_id: job.job_id.clone(),
            state: "queued".into(),
            opened: false,
            at: ditto_store::time::now(),
        });
        if a.previews.len() > 20 {
            a.previews.remove(0);
        }
        generated::save(tx, &a)?;
    } else {
        a.validation_job_id = Some(job.job_id.clone());
        a.state = ArtifactState::Validating;
        generated::save(tx, &a)?;
    }
    Ok(job)
}
fn materialize(
    paths: &ditto_store::Paths,
    a: &GeneratedArtifact,
) -> Result<packages::Unpacked, StoreError> {
    let sha = a.bundle_sha256.trim_start_matches("sha256:").to_owned();
    let directory = paths.package_dir(&sha);
    if !directory.exists() {
        let stage = paths.staging().join(&a.artifact_id);
        fs::create_dir_all(&stage)?;
        for (relative, source) in &a.source_files {
            let target = stage.join(relative);
            if let Some(parent) = target.parent() {
                fs::create_dir_all(parent)?;
            }
            fs::write(&target, source)?;
            fs::File::open(&target)?.sync_all()?;
        }
        fs::create_dir_all(
            directory
                .parent()
                .ok_or_else(|| StoreError::Invalid("package directory".into()))?,
        )?;
        fs::rename(stage, &directory)?;
        for relative in a.source_files.keys() {
            fs::set_permissions(directory.join(relative), fs::Permissions::from_mode(0o400))?;
        }
    }
    for (relative, source) in &a.source_files {
        if fs::read_to_string(directory.join(relative))? != *source {
            return Err(StoreError::Invalid(
                "generated package content changed".into(),
            ));
        }
    }
    Ok(packages::Unpacked {
        sha256: sha,
        tree_sha256: packages::tree_digest(&directory)?,
        manifest: a.manifest.clone(),
        directory,
        already_present: false,
    })
}
fn activate(core: &Arc<Core>, caller: &Caller, call: &Call<'_>) -> Handled {
    let input: GenerationActivateInput = call.input()?;
    let a = core.read(|c| generated::get(c, &input.artifact_id))?;
    if input.idempotency_key.is_empty() || input.idempotency_key.len() > 128 {
        return Err(CoreError::invalid("invalid activation key"));
    }
    let key = format!(
        "generated-activate:{}",
        ditto_protocol::jcs::digest(
            &json!({"subject":caller.subject.as_str(),"key":input.idempotency_key})
        )
    );
    if let Some(stored) = core.read(|c| ditto_store::changes::by_idempotency_key(c, &key))? {
        let (_, base) =
            core.read(|c| ditto_store::profiles::revision(c, &stored.record.base_revision))?;
        let matches_entry = |id: &str| {
            base.entry(id)
                .is_some_and(|e| e.package == a.description.plugin_id)
                && input.entry_id.as_ref().is_none_or(|wanted| wanted == id)
        };
        let same = stored.record.base_revision == input.base_revision
            && !stored.record.ops.is_empty()
            && stored.record.ops.iter().all(|op| match op {
                ChangeOp::AddEntry { entry, slot } => {
                    input.entry_id.is_none()
                        && entry.package == a.description.plugin_id
                        && entry.version == a.description.version
                        && slot.as_deref() == Some("ui.generated_panel")
                }
                ChangeOp::UpgradeEntry {
                    entry_id,
                    to_version,
                    ..
                } => matches_entry(entry_id) && to_version == &a.description.version,
                ChangeOp::SetEntryDisabled {
                    entry_id,
                    disabled: false,
                } => {
                    matches_entry(entry_id)
                        && base
                            .entry(entry_id)
                            .is_some_and(|e| e.version == a.description.version)
                }
                _ => false,
            });
        if !same {
            return Err(CoreError::new(
                ditto_protocol::ErrorName::Conflict,
                "activation key has another target",
            ));
        }
        return Ok((json!(stored.record), true));
    }
    if !generated::approved(&a) || !generated::integrity(&a) {
        return Err(CoreError::invalid(
            "artifact is not published and validated",
        ));
    }
    let (_, _, document) = router::active_document(core)?;
    let mut ops = Vec::new();
    let existing = if let Some(id) = &input.entry_id {
        Some(
            document
                .entry(id)
                .ok_or_else(|| CoreError::not_found("generated entry"))?,
        )
    } else {
        document
            .entries
            .iter()
            .find(|e| e.package == a.description.plugin_id && !e.disabled)
    };
    if let Some(entry) = existing {
        if entry.package != a.description.plugin_id {
            return Err(CoreError::invalid("the entry belongs to another plugin"));
        }
        if entry.version != a.description.version {
            ops.push(ChangeOp::UpgradeEntry {
                entry_id: entry.entry_id.clone(),
                from_version: entry.version.clone(),
                to_version: a.description.version.clone(),
            });
        }
        if entry.disabled {
            ops.push(ChangeOp::SetEntryDisabled {
                entry_id: entry.entry_id.clone(),
                disabled: false,
            });
        }
    } else {
        ops.push(ChangeOp::AddEntry {
            entry: NewEntry {
                package: a.description.plugin_id.clone(),
                version: a.description.version.clone(),
                host: HostKind::Qml,
                config: json!({}),
                disabled: false,
            },
            slot: Some("ui.generated_panel".into()),
        });
    }
    if ops.is_empty() {
        return Err(CoreError::invalid("this version is already active"));
    }
    let proposal = Proposal {
        profile_id: None,
        base_revision: input.base_revision,
        ops,
        mode: ChangeMode::Apply,
        idempotency_key: Some(key),
        request_operation_id: call.operation_id.clone(),
        origin: router::origin_for(core, caller, call, Some("generated-plugin".into()))?,
        subject: caller.subject.0.clone(),
        target: None,
    };
    router::run_proposal(core, caller, proposal, call)
}
/// Called atomically with the job result; only the trusted internal worker's
/// persisted job parameters can select which artifact this report concerns.
pub fn finish_job(c: &rusqlite::Connection, job: &Job) -> ditto_store::StoreResult<()> {
    if !matches!(
        job.kind.as_str(),
        "generation.validate" | "generation.preview"
    ) {
        return Ok(());
    }
    let params: String = c.query_row(
        "SELECT params_json FROM jobs WHERE job_id=?1",
        [&job.job_id],
        |r| r.get(0),
    )?;
    let value: Value = serde_json::from_str(&params)?;
    let id = value["artifact"]["artifact_id"]
        .as_str()
        .ok_or_else(|| StoreError::Invalid("generation job artifact".into()))?;
    if job.kind == "generation.preview" {
        return preview_event(c, job, false);
    }
    let artifact = generated::get(c, id)?;
    if artifact.state != ArtifactState::Validating
        || artifact.validation_job_id.as_deref() != Some(&job.job_id)
    {
        return Ok(());
    }
    let report = job
        .result
        .clone()
        .and_then(|v| serde_json::from_value::<GenerationValidation>(v).ok());
    generated::validation_finished(c, id, &job.job_id, report, job.error_key.as_deref())?;
    Ok(())
}

pub fn preview_event(
    c: &rusqlite::Connection,
    job: &Job,
    opened: bool,
) -> ditto_store::StoreResult<()> {
    if job.kind != "generation.preview" {
        return Ok(());
    }
    let text: String = c.query_row(
        "SELECT params_json FROM jobs WHERE job_id=?1",
        [&job.job_id],
        |r| r.get(0),
    )?;
    let params: Value = serde_json::from_str(&text)?;
    let id = params["artifact"]["artifact_id"]
        .as_str()
        .ok_or_else(|| StoreError::Invalid("preview artifact".into()))?;
    let mut a = generated::get(c, id)?;
    if let Some(record) = a.previews.iter_mut().find(|p| p.job_id == job.job_id) {
        record.opened |= opened;
        record.state = serde_json::to_value(job.state)?
            .as_str()
            .unwrap_or("failed")
            .into();
        record.at = ditto_store::time::now();
        generated::save(c, &a)?;
    }
    Ok(())
}

/// Boot reconciliation never replays an interrupted candidate.
pub fn reconcile(c: &rusqlite::Connection) -> ditto_store::StoreResult<()> {
    // Committed history is part of the Profile transaction. Backfill terminal
    // failure records whose announcement was interrupted by a crash.
    for stored in ditto_store::changes::list(c, None, None, 100)? {
        if stored.record.state.is_terminal()
            && stored.target_document.as_ref().is_some_and(|d| {
                d.entries
                    .iter()
                    .any(|e| e.package.starts_with("local.generated."))
            })
        {
            if let Err(error) = generated::record_activation(c, &stored.record) {
                crate::log::event(
                    "generation.journal_recovery_failed",
                    &[
                        ("change_id", &stored.record.change_id),
                        ("reason", &error.to_string()),
                        ("reason_code", crate::log::store_error_code(&error)),
                    ],
                );
            }
        }
    }

    let mut statement=c.prepare("SELECT artifact_json FROM generated_artifacts WHERE json_extract(artifact_json,'$.state')='validating' OR EXISTS(SELECT 1 FROM json_each(artifact_json,'$.previews') p WHERE json_extract(p.value,'$.state') IN ('queued','running','cancelling'))")?;
    let rows = statement
        .query_map([], |r| r.get::<_, String>(0))?
        .collect::<Result<Vec<_>, _>>()?;
    drop(statement);
    for row in rows {
        let a: GeneratedArtifact = serde_json::from_str(&row)?;
        for preview in &a.previews {
            let job = jobs::get(c, &preview.job_id)?;
            if matches!(
                job.state,
                JobState::Succeeded | JobState::Failed | JobState::Cancelled
            ) {
                preview_event(c, &job, false)?;
            }
        }
        if let Some(id) = a.validation_job_id {
            let job = jobs::get(c, &id)?;
            if matches!(
                job.state,
                JobState::Succeeded | JobState::Failed | JobState::Cancelled
            ) {
                finish_job(c, &job)?;
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    fn budget_store() -> (
        ditto_store::Paths,
        ditto_store::WriterLock,
        ditto_store::Store,
    ) {
        let root =
            std::env::temp_dir().join(format!("ditto-g3-budget-{}", ditto_protocol::ids::ulid()));
        let paths = ditto_store::Paths::under(&root);
        let lock = ditto_store::WriterLock::acquire(&paths.lock()).unwrap();
        let (store, _) = ditto_store::Store::open_writer(&paths, &lock).unwrap();
        (paths, lock, store)
    }
    fn precreate(store: &mut ditto_store::Store, count: usize) -> Vec<GeneratedArtifact> {
        (0..count)
            .map(|index| {
                store
                    .write(|tx| {
                        let mut description = Description::parse(include_bytes!(
                            "../../ditto-generation/examples/tasks-summary.json"
                        ))
                        .unwrap();
                        description.plugin_id = format!("local.generated.budget_{index}");
                        generated::create(
                            tx,
                            &GenerateInput {
                                description,
                                request_summary: "budget fixture".into(),
                                parent_id: None,
                                idempotency_key: format!("candidate-{index}"),
                            },
                            GenerationOrigin {
                                request_summary: "budget fixture".into(),
                                turn_id: Some("same-turn".into()),
                                model: None,
                            },
                        )
                    })
                    .unwrap()
            })
            .collect()
    }
    fn queue(
        store: &mut ditto_store::Store,
        a: &GeneratedArtifact,
        root: &std::path::Path,
    ) -> Result<Job, StoreError> {
        store.write(|tx| {
            enqueue(
                tx,
                &GenerationJobInput {
                    artifact_id: a.artifact_id.clone(),
                    idempotency_key: "validation".into(),
                },
                false,
                "cli",
                root,
            )
        })
    }
    #[test]
    fn precreated_candidates_reserve_the_turn_budget_before_enqueue() {
        // Queued, failed and mixed reservations all share the same admission cap.
        for finished in [0, 2, 4] {
            let (paths, lock, mut store) = budget_store();
            let candidates = precreate(&mut store, 5);
            for (index, a) in candidates.iter().take(4).enumerate() {
                let job = queue(&mut store, a, &paths.cache).unwrap();
                if index < finished {
                    store
                        .write(|tx| {
                            generated::validation_finished(
                                tx,
                                &a.artifact_id,
                                &job.job_id,
                                None,
                                Some(&format!("error-{index}")),
                            )?;
                            Ok(())
                        })
                        .unwrap();
                }
            }
            let before = jobs::list(store.connection(), 100).unwrap();
            assert_eq!(before.len(), 4); // Initial attempt plus three repairs.
            assert!(matches!(
                queue(&mut store, &candidates[4], &paths.cache),
                Err(StoreError::Conflict(_))
            ));
            assert_eq!(jobs::list(store.connection(), 100).unwrap(), before);
            assert_eq!(
                generated::get(store.connection(), &candidates[4].artifact_id).unwrap(),
                candidates[4]
            );
            // An idempotent readback is still allowed after reservations fill.
            let original = generated::get(store.connection(), &candidates[0].artifact_id)
                .unwrap()
                .validation_job_id
                .unwrap();
            assert_eq!(
                queue(&mut store, &candidates[0], &paths.cache)
                    .unwrap()
                    .job_id,
                original
            );
            drop(store);
            drop(lock);
            std::fs::remove_dir_all(paths.data.parent().unwrap()).unwrap();
        }
    }
    #[test]
    fn candidate_created_before_turn_stop_cannot_enqueue_validation() {
        for repeated in [false, true] {
            let (paths, lock, mut store) = budget_store();
            let candidates = precreate(&mut store, 3);
            let job = queue(&mut store, &candidates[0], &paths.cache).unwrap();
            store
                .write(|tx| {
                    let terminal =
                        jobs::finish(tx, &job.job_id, JobState::Failed, None, Some("same error"))?;
                    finish_job(tx, &terminal)?;
                    let mut failed = generated::get(tx, &candidates[0].artifact_id)?;
                    if !repeated {
                        failed.repair.stopped = true;
                        generated::save(tx, &failed)?;
                    }
                    Ok(())
                })
                .unwrap();
            if repeated {
                let job = queue(&mut store, &candidates[1], &paths.cache).unwrap();
                store
                    .write(|tx| {
                        let terminal = jobs::finish(
                            tx,
                            &job.job_id,
                            JobState::Failed,
                            None,
                            Some("same error"),
                        )?;
                        finish_job(tx, &terminal)?;
                        Ok(())
                    })
                    .unwrap();
            }
            let before = jobs::list(store.connection(), 100).unwrap();
            assert!(matches!(
                queue(&mut store, &candidates[2], &paths.cache),
                Err(StoreError::Conflict(_))
            ));
            assert_eq!(jobs::list(store.connection(), 100).unwrap(), before);
            assert_eq!(
                generated::get(store.connection(), &candidates[2].artifact_id).unwrap(),
                candidates[2]
            );
            drop(store);
            drop(lock);
            std::fs::remove_dir_all(paths.data.parent().unwrap()).unwrap();
        }
    }

    #[test]
    fn preview_and_explicit_new_turn_survive_a_stopped_budget() {
        let (paths, lock, mut store) = budget_store();
        let candidates = precreate(&mut store, 2);
        store
            .write(|tx| {
                let mut stopped = candidates[0].clone();
                stopped.repair.stopped = true;
                generated::save(tx, &stopped)?;
                let mut validated = candidates[1].clone();
                // Forged report is only a fixture; preview admission is tested here,
                // not isolation or native rendering.
                let vector: Value = serde_json::from_str(include_str!(
                    "../../../tests/contract-vectors/0.3/shape-generation-validation-full.json"
                ))
                .unwrap();
                let mut report: GenerationValidation =
                    serde_json::from_value(vector["value"].clone()).unwrap();
                report.bundle_sha256 = validated.bundle_sha256.clone();
                validated.validation = Some(report);
                validated.state = ArtifactState::Validated;
                generated::save(tx, &validated)?;
                enqueue(
                    tx,
                    &GenerationJobInput {
                        artifact_id: validated.artifact_id,
                        idempotency_key: "preview".into(),
                    },
                    true,
                    "cli",
                    &paths.cache,
                )?;
                Ok(())
            })
            .unwrap();
        assert_eq!(
            jobs::list(store.connection(), 100).unwrap()[0].kind,
            "generation.preview"
        );
        let fresh = store
            .write(|tx| {
                let mut description = candidates[0].description.clone();
                description.plugin_id = "local.generated.new_turn".into();
                generated::create(
                    tx,
                    &GenerateInput {
                        description,
                        request_summary: "explicit new request".into(),
                        parent_id: None,
                        idempotency_key: "new-turn".into(),
                    },
                    GenerationOrigin {
                        request_summary: "explicit new request".into(),
                        turn_id: Some("new-turn".into()),
                        model: None,
                    },
                )
            })
            .unwrap();
        assert_eq!(
            queue(&mut store, &fresh, &paths.cache).unwrap().kind,
            "generation.validate"
        );
        drop(store);
        drop(lock);
        std::fs::remove_dir_all(paths.data.parent().unwrap()).unwrap();
    }

    fn report_fixture(a: &GeneratedArtifact, partial: Option<&str>) -> GenerationValidation {
        let vector: Value = serde_json::from_str(include_str!(
            "../../../tests/contract-vectors/0.3/shape-generation-validation-full.json"
        ))
        .unwrap();
        let mut report: GenerationValidation =
            serde_json::from_value(vector["value"].clone()).unwrap();
        report.bundle_sha256 = a.bundle_sha256.clone();
        if let Some(diagnostic) = partial {
            report.boundary.enforcement = Enforcement::Unavailable;
            for (index, stage) in report.stages.iter_mut().enumerate() {
                stage.result = if index == 0 {
                    StageResult::Failed
                } else {
                    StageResult::NotRun
                };
                stage.diagnostic = diagnostic.into();
            }
        }
        report
    }
    fn queue_key(
        store: &mut ditto_store::Store,
        a: &GeneratedArtifact,
        paths: &ditto_store::Paths,
        key: &str,
    ) -> Result<Job, StoreError> {
        store.write(|tx| {
            enqueue(
                tx,
                &GenerationJobInput {
                    artifact_id: a.artifact_id.clone(),
                    idempotency_key: key.into(),
                },
                false,
                "cli",
                &paths.cache,
            )
        })
    }
    fn settle(
        store: &mut ditto_store::Store,
        job: &Job,
        state: JobState,
        report: Option<GenerationValidation>,
        error: Option<&str>,
    ) {
        store
            .write(|tx| {
                let result = report.map(|report| json!(report));
                let terminal = jobs::finish(tx, &job.job_id, state, result.as_ref(), error)?;
                finish_job(tx, &terminal)
            })
            .unwrap();
    }
    #[test]
    fn revalidation_cancel_and_restart_cannot_enqueue_a_fifth_build() {
        let (paths, lock, mut store) = budget_store();
        let candidates = precreate(&mut store, 3);
        let first = queue_key(&mut store, &candidates[0], &paths, "first").unwrap();
        settle(
            &mut store,
            &first,
            JobState::Failed,
            Some(report_fixture(
                &candidates[0],
                Some("first isolation failure"),
            )),
            None,
        );
        assert_eq!(
            generated::get(store.connection(), &candidates[0].artifact_id)
                .unwrap()
                .state,
            ArtifactState::InspectOnly
        );
        let second = queue_key(&mut store, &candidates[0], &paths, "retry").unwrap();
        store
            .write(|tx| {
                let cancelled = jobs::request_cancel(tx, &second.job_id)?;
                finish_job(tx, &cancelled)
            })
            .unwrap();
        assert_eq!(
            jobs::get(store.connection(), &second.job_id)
                .unwrap()
                .error_key
                .as_deref(),
            Some("job.cancelled")
        );
        let third = queue_key(&mut store, &candidates[1], &paths, "third").unwrap();
        settle(
            &mut store,
            &third,
            JobState::Failed,
            Some(report_fixture(
                &candidates[1],
                Some("different isolation failure"),
            )),
            None,
        );
        let fourth = queue_key(&mut store, &candidates[1], &paths, "retry").unwrap();
        store
            .write(|tx| {
                jobs::start(tx, &fourth.job_id, "fixture-unit")?;
                jobs::fail_interrupted(tx)?;
                reconcile(tx)
            })
            .unwrap();
        assert_eq!(
            jobs::get(store.connection(), &fourth.job_id)
                .unwrap()
                .error_key
                .as_deref(),
            Some("job.interrupted")
        );
        let before = jobs::list(store.connection(), 100).unwrap();
        assert_eq!(before.len(), 4);
        assert!(
            matches!(
                queue_key(&mut store, &candidates[2], &paths, "fifth"),
                Err(StoreError::Conflict(_))
            ),
            "a fifth build was admitted after two overwritten validation attempts"
        );
        assert_eq!(jobs::list(store.connection(), 100).unwrap(), before);
        assert_eq!(
            generated::get(store.connection(), &candidates[2].artifact_id).unwrap(),
            candidates[2]
        );
        drop(store);
        drop(lock);
        std::fs::remove_dir_all(paths.data.parent().unwrap()).unwrap();
    }

    #[test]
    fn validation_job_outcomes_keep_individual_attempts() {
        for outcome in [
            "queued",
            "running",
            "cancelling",
            "cancelled",
            "running_cancelled",
            "interrupted",
            "failed",
            "inspect_only",
            "missing_report",
            "malformed_report",
            "wrong_hash",
            "unknown",
            "error_with_full_report",
        ] {
            let (paths, lock, mut store) = budget_store();
            let candidates = precreate(&mut store, 5);
            let first = queue_key(&mut store, &candidates[0], &paths, "first").unwrap();
            match outcome {
                "queued" => {}
                "running" | "cancelling" | "interrupted" => {
                    store
                        .write(|tx| {
                            jobs::start(tx, &first.job_id, "fixture")?;
                            if outcome == "cancelling" {
                                jobs::request_cancel(tx, &first.job_id)?;
                            }
                            if outcome == "interrupted" {
                                jobs::fail_interrupted(tx)?;
                                reconcile(tx)?;
                            }
                            Ok(())
                        })
                        .unwrap();
                }
                "cancelled" => {
                    store
                        .write(|tx| {
                            let job = jobs::request_cancel(tx, &first.job_id)?;
                            finish_job(tx, &job)
                        })
                        .unwrap();
                }
                "running_cancelled" => {
                    store
                        .write(|tx| {
                            jobs::start(tx, &first.job_id, "fixture")?;
                            jobs::request_cancel(tx, &first.job_id)?;
                            let cancelled = jobs::finish(
                                tx,
                                &first.job_id,
                                JobState::Cancelled,
                                None,
                                Some("job.cancelled"),
                            )?;
                            finish_job(tx, &cancelled)
                        })
                        .unwrap();
                }
                "failed" => settle(
                    &mut store,
                    &first,
                    JobState::Failed,
                    None,
                    Some("fixture.failure"),
                ),
                "inspect_only" => settle(
                    &mut store,
                    &first,
                    JobState::Failed,
                    Some(report_fixture(&candidates[0], Some("isolation"))),
                    None,
                ),
                "missing_report" => settle(&mut store, &first, JobState::Succeeded, None, None),
                "malformed_report" => {
                    store
                        .write(|tx| {
                            let job = jobs::finish(
                                tx,
                                &first.job_id,
                                JobState::Succeeded,
                                Some(&json!({"not":"a report"})),
                                None,
                            )?;
                            finish_job(tx, &job)
                        })
                        .unwrap();
                }
                "wrong_hash" => settle(
                    &mut store,
                    &first,
                    JobState::Succeeded,
                    Some(report_fixture(&candidates[1], None)),
                    None,
                ),
                "error_with_full_report" => settle(
                    &mut store,
                    &first,
                    JobState::Succeeded,
                    Some(report_fixture(&candidates[0], None)),
                    Some("fixture.error"),
                ),
                "unknown" => {
                    // Unknown persisted state must not become success through
                    // the protocol's display fallback or mutable artifact.
                    store
                        .write(|tx| {
                            tx.pragma_update(None, "ignore_check_constraints", true)?;
                            tx.execute(
                                "UPDATE jobs SET state='unknown' WHERE job_id=?1",
                                [&first.job_id],
                            )?;
                            tx.pragma_update(None, "ignore_check_constraints", false)?;
                            Ok(())
                        })
                        .unwrap();
                }
                _ => unreachable!(),
            }
            for a in candidates.iter().skip(1).take(3) {
                queue(&mut store, a, &paths.cache).unwrap();
            }
            let before = jobs::list(store.connection(), 100).unwrap();
            assert!(
                matches!(
                    queue(&mut store, &candidates[4], &paths.cache),
                    Err(StoreError::Conflict(_))
                ),
                "{outcome}"
            );
            assert_eq!(jobs::list(store.connection(), 100).unwrap(), before);
            // Candidate creation must use the same ledger as enqueue.
            let mut description = candidates[4].description.clone();
            description.plugin_id = "local.generated.bypass".into();
            assert!(matches!(
                store.write(|tx| generated::create(
                    tx,
                    &GenerateInput {
                        description,
                        request_summary: "bypass".into(),
                        parent_id: None,
                        idempotency_key: "bypass".into(),
                    },
                    candidates[4].origin.clone()
                )),
                Err(StoreError::Conflict(_))
            ));
            drop(store);
            drop(lock);
            std::fs::remove_dir_all(paths.data.parent().unwrap()).unwrap();
        }
    }

    #[test]
    fn validation_success_releases_only_its_own_attempt() {
        for repaired_child in [false, true] {
            let (paths, lock, mut store) = budget_store();
            let candidates = precreate(&mut store, 5);
            let failed = queue_key(&mut store, &candidates[0], &paths, "failed").unwrap();
            let mut failure = report_fixture(&candidates[0], Some("isolation"));
            if repaired_child {
                failure.boundary.enforcement = Enforcement::Full;
            }
            settle(&mut store, &failed, JobState::Failed, Some(failure), None);
            let validated = if repaired_child {
                store
                    .write(|tx| {
                        let mut description = candidates[0].description.clone();
                        description.version = "1.0.1".into();
                        generated::create(
                            tx,
                            &GenerateInput {
                                description,
                                request_summary: "repair".into(),
                                parent_id: Some(candidates[0].artifact_id.clone()),
                                idempotency_key: "repair-child".into(),
                            },
                            candidates[0].origin.clone(),
                        )
                    })
                    .unwrap()
            } else {
                candidates[0].clone()
            };
            let success = queue_key(&mut store, &validated, &paths, "success").unwrap();
            settle(
                &mut store,
                &success,
                JobState::Succeeded,
                Some(report_fixture(&validated, None)),
                None,
            );
            assert_eq!(
                generated::get(store.connection(), &validated.artifact_id)
                    .unwrap()
                    .state,
                ArtifactState::Validated
            );
            assert_eq!(
                queue_key(&mut store, &validated, &paths, "success")
                    .unwrap()
                    .job_id,
                success.job_id
            );
            // Preview has its own job but leaves the three free build slots intact.
            store
                .write(|tx| {
                    enqueue(
                        tx,
                        &GenerationJobInput {
                            artifact_id: validated.artifact_id.clone(),
                            idempotency_key: "preview".into(),
                        },
                        true,
                        "cli",
                        &paths.cache,
                    )
                })
                .unwrap();
            for a in candidates.iter().skip(1).take(3) {
                queue(&mut store, a, &paths.cache).unwrap();
            }
            let before = jobs::list(store.connection(), 100).unwrap();
            assert_eq!(before.len(), 6); // One failure, one success, preview, three builds.
            assert!(matches!(
                queue(&mut store, &candidates[4], &paths.cache),
                Err(StoreError::Conflict(_))
            ));
            assert_eq!(jobs::list(store.connection(), 100).unwrap(), before);
            assert_eq!(
                jobs::get(store.connection(), &failed.job_id).unwrap().state,
                JobState::Failed
            );
            drop(store);
            drop(lock);
            std::fs::remove_dir_all(paths.data.parent().unwrap()).unwrap();
        }
    }

    #[test]
    fn independent_successes_and_new_turn_do_not_share_spent_attempts() {
        let (paths, lock, mut store) = budget_store();
        let candidates = precreate(&mut store, 10);
        for a in candidates.iter().take(6) {
            let job = queue(&mut store, a, &paths.cache).unwrap();
            settle(
                &mut store,
                &job,
                JobState::Succeeded,
                Some(report_fixture(a, None)),
                None,
            );
        }
        for a in candidates.iter().skip(6) {
            queue(&mut store, a, &paths.cache).unwrap();
        }
        // Neither a reconnect nor artifact state edits can release queued jobs:
        // attribution is saved per job and readback has no budget side effects.
        store
            .write(|tx| {
                let mut edited = generated::get(tx, &candidates[6].artifact_id)?;
                edited.origin.turn_id = Some("different-artifact-origin".into());
                edited.state = ArtifactState::Validated;
                generated::save(tx, &edited)?;
                Ok(())
            })
            .unwrap();
        let reader = ditto_store::Store::open_reader(&paths).unwrap();
        assert!(generated::check_turn_budget(reader.connection(), &candidates[0].origin).is_err());
        assert_eq!(jobs::list(reader.connection(), 100).unwrap().len(), 10);
        let mut description = candidates[0].description.clone();
        description.plugin_id = "local.generated.explicit_new_turn".into();
        let fresh = store
            .write(|tx| {
                generated::create(
                    tx,
                    &GenerateInput {
                        description,
                        request_summary: "explicit new turn".into(),
                        parent_id: None,
                        idempotency_key: "new-turn".into(),
                    },
                    GenerationOrigin {
                        request_summary: "explicit new turn".into(),
                        turn_id: Some("new-user-turn".into()),
                        model: None,
                    },
                )
            })
            .unwrap();
        assert!(queue(&mut store, &fresh, &paths.cache).is_ok());
        drop(reader);
        drop(store);
        drop(lock);
        std::fs::remove_dir_all(paths.data.parent().unwrap()).unwrap();
    }

    #[test]
    fn interrupted_validation_is_settled_once_without_replay() {
        let root =
            std::env::temp_dir().join(format!("ditto-g3-recovery-{}", ditto_protocol::ids::ulid()));
        let paths = ditto_store::Paths::under(&root);
        let lock = ditto_store::WriterLock::acquire(&paths.lock()).unwrap();
        let (mut store, _) = ditto_store::Store::open_writer(&paths, &lock).unwrap();
        let a = store
            .write(|tx| {
                let description = Description::parse(include_bytes!(
                    "../../ditto-generation/examples/tasks-summary.json"
                ))
                .unwrap();
                let mut a = generated::create(
                    tx,
                    &GenerateInput {
                        description,
                        request_summary: "test".into(),
                        parent_id: None,
                        idempotency_key: "candidate".into(),
                    },
                    GenerationOrigin {
                        request_summary: "test".into(),
                        turn_id: None,
                        model: None,
                    },
                )?;
                let job = jobs::enqueue(
                    tx,
                    "generation.validate",
                    "cli",
                    &json!({"artifact":a}),
                    "validation",
                    45000,
                )?;
                jobs::start(tx, &job.job_id, "test-unit")?;
                a.validation_job_id = Some(job.job_id);
                a.state = ArtifactState::Validating;
                generated::save(tx, &a)?;
                Ok(a)
            })
            .unwrap();
        store
            .write(|tx| {
                jobs::fail_interrupted(tx)?;
                reconcile(tx)?;
                Ok(())
            })
            .unwrap();
        let failed = generated::get(store.connection(), &a.artifact_id).unwrap();
        assert_eq!(failed.state, ArtifactState::Failed);
        assert_eq!(failed.repair.failure_fingerprints.len(), 1);
        store.write(|tx| reconcile(tx)).unwrap();
        assert_eq!(
            generated::get(store.connection(), &a.artifact_id).unwrap(),
            failed
        );
        drop(store);
        drop(lock);
        std::fs::remove_dir_all(root).unwrap();
    }
}
