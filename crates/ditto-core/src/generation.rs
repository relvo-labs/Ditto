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
            let a = router::coordinate(core, call, move |c| {
                c.store().write(|tx| generated::create(tx, &input, source))
            })??;
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
            let a = router::coordinate(core, call, move |c| {
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
            })??;
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
            let value = router::coordinate(core, call, move |c| {
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
            })??;
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
    let job = router::coordinate(core, call, move |c| {
        c.store().write(|tx| {
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
            let params = json!({"artifact":candidate,"work_root":root});
            let job = jobs::enqueue(
                tx,
                kind,
                &owner,
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
        })
    })??;
    core.jobs.wake();
    Ok((json!(job), true))
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
