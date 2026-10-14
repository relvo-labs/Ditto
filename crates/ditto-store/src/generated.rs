//! Core-owned immutable generation source, validation/activation journal,
//! persistent repair budget and transactional plugin data migrations.
use crate::{time, StoreError, StoreResult};
use ditto_protocol::{generation::*, ids, jcs, profile::ProfileDocument};
use rusqlite::{params, Connection, OptionalExtension};
use serde_json::{json, Value};
use std::collections::BTreeSet;

pub fn get(c: &Connection, id: &str) -> StoreResult<GeneratedArtifact> {
    let text: String = c
        .query_row(
            "SELECT artifact_json FROM generated_artifacts WHERE artifact_id=?1",
            [id],
            |r| r.get(0),
        )
        .optional()?
        .ok_or_else(|| StoreError::NotFound("generated artifact".into()))?;
    Ok(serde_json::from_str(&text)?)
}
pub fn by_package(
    c: &Connection,
    plugin: &str,
    version: &str,
) -> StoreResult<Option<GeneratedArtifact>> {
    let id: Option<String> = c
        .query_row(
            "SELECT artifact_id FROM generated_artifacts WHERE plugin_id=?1 AND version=?2",
            params![plugin, version],
            |r| r.get(0),
        )
        .optional()?;
    id.map(|id| get(c, &id)).transpose()
}
pub fn list(c: &Connection) -> StoreResult<Vec<GeneratedArtifact>> {
    let mut statement = c.prepare(
        "SELECT artifact_id FROM generated_artifacts ORDER BY artifact_id DESC LIMIT 10",
    )?;
    let ids = statement
        .query_map([], |r| r.get::<_, String>(0))?
        .collect::<Result<Vec<_>, _>>()?;
    ids.iter().map(|id| get(c, id)).collect()
}
pub fn save(c: &Connection, a: &GeneratedArtifact) -> StoreResult<()> {
    c.execute(
        "UPDATE generated_artifacts SET artifact_json=?2 WHERE artifact_id=?1",
        params![a.artifact_id, serde_json::to_string(a)?],
    )?;
    Ok(())
}
pub fn create(
    c: &Connection,
    input: &GenerateInput,
    origin: GenerationOrigin,
) -> StoreResult<GeneratedArtifact> {
    if input.idempotency_key.is_empty()
        || input.idempotency_key.len() > 128
        || origin.request_summary.trim().is_empty()
        || origin.request_summary.len() > 1024
    {
        return Err(StoreError::Invalid("generation request bounds".into()));
    }
    let hash = jcs::digest(&json!(input));
    let existing: Option<(String, String)> = c
        .query_row(
            "SELECT artifact_id,create_hash FROM generated_artifacts WHERE create_key=?1",
            [&input.idempotency_key],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .optional()?;
    if let Some((id, old)) = existing {
        if old != hash {
            return Err(StoreError::Conflict(
                "generation key has another payload".into(),
            ));
        }
        return get(c, &id);
    }
    let (manifest, source_files, dependencies, bundle_sha256) =
        bundle(&input.description).map_err(StoreError::Invalid)?;
    if let Some(turn) = &origin.turn_id {
        let failures:i64=c.query_row("SELECT count(*) FROM generated_artifacts WHERE json_extract(artifact_json,'$.origin.turn_id')=?1 AND json_extract(artifact_json,'$.state') IN ('failed','inspect_only')",[turn],|r|r.get(0))?;
        let repeated:bool=c.query_row("SELECT EXISTS(SELECT 1 FROM generated_artifacts WHERE json_extract(artifact_json,'$.origin.turn_id')=?1 AND json_extract(artifact_json,'$.state') IN ('failed','inspect_only') GROUP BY json_extract(artifact_json,'$.repair.failure_fingerprints[#-1]') HAVING count(*)>=2 AND json_extract(artifact_json,'$.repair.failure_fingerprints[#-1]') IS NOT NULL)",[turn],|r|r.get(0))?;
        let stopped: bool = c.query_row(
            "SELECT EXISTS(SELECT 1 FROM generated_artifacts WHERE json_extract(artifact_json,'$.origin.turn_id')=?1 AND json_extract(artifact_json,'$.repair.stopped')=1)",
            [turn],
            |r| r.get(0),
        )?;
        if failures >= 4 || repeated || stopped {
            return Err(StoreError::Conflict(
                "this turn's generation repair budget is exhausted".into(),
            ));
        }
    }
    let parent = input.parent_id.as_ref().map(|id| get(c, id)).transpose()?;
    let mut repair = RepairBudget::default();
    let mut changed_fields = Vec::new();
    if let Some(p) = &parent {
        if p.description.plugin_id != input.description.plugin_id
            || version(&input.description.version) <= version(&p.description.version)
        {
            return Err(StoreError::Conflict(
                "a modification needs the same plugin and a new version".into(),
            ));
        }
        if input.description.data.schema_version < p.description.data.schema_version
            || (input.description.data.fields != p.description.data.fields
                && input.description.data.schema_version <= p.description.data.schema_version)
        {
            return Err(StoreError::Invalid(
                "changed data fields require an increased schema version".into(),
            ));
        }
        if matches!(
            p.state,
            ArtifactState::Candidate | ArtifactState::Validating
        ) {
            return Err(StoreError::Conflict(
                "finish parent validation before creating a modification".into(),
            ));
        }
        if matches!(p.state, ArtifactState::Failed | ArtifactState::InspectOnly)
            && (origin.turn_id.is_none() || origin.turn_id == p.origin.turn_id)
        {
            let children: i64 = c.query_row(
                "SELECT count(*) FROM generated_artifacts WHERE parent_id=?1",
                [&p.artifact_id],
                |r| r.get(0),
            )?;
            if children > 0 {
                return Err(StoreError::Conflict(
                    "a repair already exists; continue from that version".into(),
                ));
            }
            if p.repair.stopped || p.repair.attempts >= 3 {
                return Err(StoreError::Conflict(
                    "generation repair budget exhausted".into(),
                ));
            }
            repair = p.repair.clone();
            repair.attempts += 1;
        }
        let before = json!(p.description);
        let after = json!(input.description);
        for key in ["title", "width", "accent", "content", "data"] {
            if before[key] != after[key] {
                changed_fields.push(key.into());
            }
        }
    } else if c.query_row(
        "SELECT count(*) FROM generated_artifacts WHERE plugin_id=?1",
        [&input.description.plugin_id],
        |r| r.get::<_, i64>(0),
    )? > 0
    {
        return Err(StoreError::Conflict(
            "an existing generated plugin requires parent_id".into(),
        ));
    }
    let artifact = GeneratedArtifact {
        artifact_id: ids::new("art"),
        description: input.description.clone(),
        config_schema: manifest.config_schema.clone(),
        manifest,
        dependencies,
        source_files,
        origin,
        parent_id: input.parent_id.clone(),
        bundle_sha256,
        created_at: time::now(),
        state: ArtifactState::Candidate,
        validation: None,
        validation_job_id: None,
        repair,
        activations: vec![],
        previews: vec![],
        changed_fields,
    };
    c.execute(
        "INSERT INTO generated_artifacts VALUES(?1,?2,?3,?4,?5,?6,?7,?8)",
        params![
            artifact.artifact_id,
            artifact.description.plugin_id,
            artifact.description.version,
            artifact.parent_id,
            artifact.bundle_sha256,
            input.idempotency_key,
            hash,
            serde_json::to_string(&artifact)?
        ],
    )?;
    Ok(artifact)
}
pub fn validation_finished(
    c: &Connection,
    id: &str,
    job: &str,
    validation: Option<GenerationValidation>,
    error: Option<&str>,
) -> StoreResult<GeneratedArtifact> {
    let mut a = get(c, id)?;
    if a.validation_job_id.as_deref() != Some(job) {
        return Err(StoreError::Conflict(
            "validation belongs to another attempt".into(),
        ));
    }
    let passed = validation
        .as_ref()
        .is_some_and(|v| v.passed(&a.bundle_sha256));
    a.state = if passed {
        ArtifactState::Validated
    } else if validation
        .as_ref()
        .is_some_and(|v| v.boundary.enforcement != Enforcement::Full)
    {
        ArtifactState::InspectOnly
    } else {
        ArtifactState::Failed
    };
    if !passed {
        // Compare persisted reports, so a restart cannot reset progress. Only
        // a contiguous prefix in the prescribed order counts as advancement;
        // changing diagnostics at the same gate is not another repair budget.
        let progress = |report: Option<&GenerationValidation>| {
            report.map_or(0, |v| {
                v.stages
                    .iter()
                    .zip(VALIDATION_STAGES)
                    .take_while(|(e, stage)| e.stage == *stage && e.result == StageResult::Passed)
                    .count()
            })
        };
        let no_progress = if a.repair.attempts > 0 {
            let parent = a.parent_id.as_ref().map(|id| get(c, id)).transpose()?;
            parent.is_none_or(|p| progress(validation.as_ref()) <= progress(p.validation.as_ref()))
        } else {
            false
        };
        let fingerprint = validation
            .as_ref()
            .and_then(|v| v.stages.iter().find(|s| s.result == StageResult::Failed))
            .map(|s| jcs::digest(&json!([s.stage, s.diagnostic])))
            .unwrap_or_else(|| jcs::digest(&json!(error.unwrap_or("validation_unavailable"))));
        a.repair.failure_fingerprints.push(fingerprint.clone());
        a.repair.stopped = no_progress
            || a.repair.attempts >= 3
            || a.repair
                .failure_fingerprints
                .iter()
                .filter(|f| **f == fingerprint)
                .count()
                >= 2;
    }
    a.validation = validation;
    save(c, &a)?;
    Ok(a)
}
pub fn approved(a: &GeneratedArtifact) -> bool {
    matches!(a.state, ArtifactState::Published | ArtifactState::Active)
        && a.validation
            .as_ref()
            .is_some_and(|v| v.passed(&a.bundle_sha256))
}
pub fn integrity(a: &GeneratedArtifact) -> bool {
    bundle(&a.description).is_ok_and(|(m, files, deps, hash)| {
        m == a.manifest
            && files == a.source_files
            && deps == a.dependencies
            && hash == a.bundle_sha256
            && a.config_schema == m.config_schema
    })
}

pub fn record_activation(
    c: &Connection,
    record: &ditto_protocol::change::ChangeRecord,
) -> StoreResult<()> {
    use ditto_protocol::change::ChangeState;
    if !record.state.is_terminal() {
        return Ok(());
    }
    let stored = crate::changes::get(c, &record.change_id)?;
    let Some(target) = stored.target_document else {
        return Ok(());
    };
    let (_, base) = crate::profiles::revision(c, &record.base_revision)?;
    for entry in target.entries.iter().filter(|e| !e.disabled) {
        if base.entry(&entry.entry_id).is_some_and(|old| {
            old.package == entry.package && old.version == entry.version && !old.disabled
        }) {
            continue;
        }
        if let Some(mut a) = by_package(c, &entry.package, &entry.version)? {
            if a.activations.iter().any(|r| {
                r.change_id == record.change_id
                    && r.state == record.state.as_str()
                    && r.revision == record.committed_revision
            }) {
                continue;
            }
            a.activations.retain(|r| r.change_id != record.change_id);
            a.activations.push(ActivationRecord {
                change_id: record.change_id.clone(),
                state: record.state.as_str().into(),
                revision: record.committed_revision.clone(),
                at: time::now(),
            });
            if a.activations.len() > 100 {
                a.activations.remove(0);
            }
            if matches!(record.state, ChangeState::Aborted | ChangeState::RolledBack)
                && a.state != ArtifactState::Active
            {
                a.state = ArtifactState::Failed;
            }
            save(c, &a)?;
        }
    }
    Ok(())
}

pub fn redact_session_sources(c: &Connection, session: &str) -> StoreResult<()> {
    let mut statement=c.prepare("SELECT artifact_id FROM generated_artifacts WHERE json_extract(artifact_json,'$.origin.turn_id') IN (SELECT turn_id FROM agent_turns WHERE session_id=?1)")?;
    let ids = statement
        .query_map([session], |r| r.get::<_, String>(0))?
        .collect::<Result<Vec<_>, _>>()?;
    drop(statement);
    for id in ids {
        let mut a = get(c, &id)?;
        a.origin.request_summary = "來源對話已刪除".into();
        a.origin.turn_id = None;
        a.origin.model = None;
        save(c, &a)?;
    }
    Ok(())
}

pub fn data_get(c: &Connection, a: &GeneratedArtifact) -> StoreResult<GeneratedData> {
    let row: Option<(String,u32,i64,String)>=c.query_row("SELECT artifact_id,schema_version,revision,payload_json FROM generated_plugin_data WHERE plugin_id=?1",[&a.description.plugin_id],|r|Ok((r.get(0)?,r.get(1)?,r.get::<_,i64>(2)?,r.get(3)?))).optional()?;
    let Some((id, schema_version, revision, text)) = row else {
        return Ok(GeneratedData {
            plugin_id: a.description.plugin_id.clone(),
            schema_version: a.description.data.schema_version,
            revision: 0,
            payload: json!({}),
        });
    };
    let revision = u64::try_from(revision)
        .map_err(|_| StoreError::Invalid("negative data revision".into()))?;
    if id != a.artifact_id || schema_version != a.description.data.schema_version {
        return Err(StoreError::Conflict(
            "this plugin version cannot read the active data schema".into(),
        ));
    }
    let payload = serde_json::from_str(&text)?;
    a.description
        .data
        .validate_payload(&payload)
        .map_err(StoreError::Invalid)?;
    Ok(GeneratedData {
        plugin_id: a.description.plugin_id.clone(),
        schema_version,
        revision,
        payload,
    })
}
pub fn data_write(
    c: &Connection,
    a: &GeneratedArtifact,
    input: &GeneratedDataInput,
) -> StoreResult<GeneratedData> {
    a.description
        .data
        .validate_payload(&input.payload)
        .map_err(StoreError::Invalid)?;
    let current = data_get(c, a)?;
    if current.revision != input.expected_revision {
        return Err(StoreError::Conflict("plugin data revision stale".into()));
    }
    let revision = current
        .revision
        .checked_add(1)
        .filter(|v| *v <= 9_007_199_254_740_991)
        .ok_or_else(|| StoreError::Conflict("plugin data revision exhausted".into()))?;
    c.execute("INSERT INTO generated_plugin_data VALUES(?1,?2,?3,?4,?5) ON CONFLICT(plugin_id) DO UPDATE SET artifact_id=excluded.artifact_id,schema_version=excluded.schema_version,revision=excluded.revision,payload_json=excluded.payload_json",params![a.description.plugin_id,a.artifact_id,a.description.data.schema_version,revision as i64,serde_json::to_string(&input.payload)?])?;
    data_get(c, a)
}

fn version(s: &str) -> Vec<u32> {
    s.split('.').filter_map(|v| v.parse().ok()).collect()
}

type DataTransition = (Value, Option<(String, u32, Value)>);
fn transition(c: &Connection, a: &GeneratedArtifact) -> StoreResult<DataTransition> {
    let row:Option<(String,u32,String)>=c.query_row("SELECT artifact_id,schema_version,payload_json FROM generated_plugin_data WHERE plugin_id=?1",[&a.description.plugin_id],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?))).optional()?;
    let Some((old_id, old_version, text)) = row else {
        return Ok((json!({}), None));
    };
    let old_payload: Value = serde_json::from_str(&text)?;
    if old_id == a.artifact_id {
        a.description
            .data
            .validate_payload(&old_payload)
            .map_err(StoreError::Invalid)?;
        return Ok((old_payload, None));
    }
    let mut payload = old_payload.clone();
    let mut snapshot = None;
    if old_version < a.description.data.schema_version {
        let m = a
            .description
            .data
            .migration
            .as_ref()
            .filter(|m| m.from_version == old_version)
            .ok_or_else(|| StoreError::Conflict("no migration from active data schema".into()))?;
        let object = payload
            .as_object_mut()
            .ok_or_else(|| StoreError::Invalid("plugin data object".into()))?;
        for (from, to) in &m.rename {
            if object.contains_key(from) && object.contains_key(to) {
                return Err(StoreError::Conflict(
                    "migration would overwrite a field".into(),
                ));
            }
            if let Some(v) = object.remove(from) {
                object.insert(to.clone(), v);
            }
        }
        for k in &m.remove {
            object.remove(k);
        }
        for (k, v) in &m.defaults {
            object.entry(k).or_insert(v.clone());
        }
        if m.rollback == RollbackPolicy::Snapshot {
            snapshot = Some((old_id, old_version, old_payload));
        }
    } else if old_version > a.description.data.schema_version {
        let old = get(c, &old_id)?;
        match old
            .description
            .data
            .migration
            .as_ref()
            .map(|m| m.rollback)
            .unwrap_or(RollbackPolicy::Unavailable)
        {
            RollbackPolicy::Unavailable => {
                return Err(StoreError::Conflict(
                    "data migration is irreversible; old version cannot read new data".into(),
                ))
            }
            RollbackPolicy::Compatible => {}
            RollbackPolicy::Snapshot => {
                let text:Option<String>=c.query_row("SELECT payload_json FROM generated_data_snapshots WHERE plugin_id=?1 AND from_artifact_id=?2 AND schema_version=?3 ORDER BY rowid DESC LIMIT 1",params![a.description.plugin_id,a.artifact_id,a.description.data.schema_version],|r|r.get(0)).optional()?;
                payload = serde_json::from_str(&text.ok_or_else(|| {
                    StoreError::Conflict("rollback data snapshot unavailable".into())
                })?)?;
            }
        }
    }
    a.description
        .data
        .validate_payload(&payload)
        .map_err(StoreError::Invalid)?;
    Ok((payload, snapshot))
}
pub fn check_document(c: &Connection, document: &ProfileDocument) -> StoreResult<()> {
    let mut plugins = BTreeSet::new();
    for entry in document.entries.iter().filter(|e| !e.disabled) {
        if let Some(a) = by_package(c, &entry.package, &entry.version)? {
            if !plugins.insert(&entry.package) {
                return Err(StoreError::Conflict(
                    "generated plugin has more than one active data owner".into(),
                ));
            }
            if !approved(&a) || !integrity(&a) {
                return Err(StoreError::Invalid(
                    "generated artifact is not approved and intact".into(),
                ));
            }
            transition(c, &a)?;
        }
    }
    Ok(())
}
/// Called in the SAME SQLite transaction as the immutable Profile revision.
pub fn apply_document(
    c: &Connection,
    document: &ProfileDocument,
    change_id: &str,
) -> StoreResult<()> {
    check_document(c, document)?;
    for entry in document.entries.iter().filter(|e| !e.disabled) {
        if let Some(mut a) = by_package(c, &entry.package, &entry.version)? {
            let (payload, snapshot) = transition(c, &a)?;
            if let Some((from, version, old)) = snapshot {
                c.execute(
                    "INSERT INTO generated_data_snapshots VALUES(?1,?2,?3,?4,?5,?6,?7)",
                    params![
                        change_id,
                        a.description.plugin_id,
                        from,
                        a.artifact_id,
                        version,
                        serde_json::to_string(&old)?,
                        time::now()
                    ],
                )?;
            }
            c.execute("INSERT INTO generated_plugin_data VALUES(?1,?2,?3,1,?4) ON CONFLICT(plugin_id) DO UPDATE SET artifact_id=excluded.artifact_id,schema_version=excluded.schema_version,revision=revision+1,payload_json=excluded.payload_json WHERE artifact_id!=excluded.artifact_id",params![a.description.plugin_id,a.artifact_id,a.description.data.schema_version,serde_json::to_string(&payload)?])?;
            data_get(c, &a)?;
            a.state = ArtifactState::Active;
            save(c, &a)?;
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use ditto_protocol::profile::{EntrySpec, HostKind};
    fn candidate(
        c: &Connection,
        parent: Option<&GeneratedArtifact>,
        version: &str,
        data: DataPlan,
    ) -> GeneratedArtifact {
        let mut description = Description::parse(include_bytes!(
            "../../ditto-generation/examples/tasks-summary.json"
        ))
        .unwrap();
        description.version = version.into();
        description.data = data;
        create(
            c,
            &GenerateInput {
                description,
                request_summary: "test".into(),
                parent_id: parent.map(|a| a.artifact_id.clone()),
                idempotency_key: version.into(),
            },
            GenerationOrigin {
                request_summary: "test".into(),
                turn_id: None,
                model: None,
            },
        )
        .unwrap()
    }
    // Reports are forged ONLY in this store unit fixture. Production accepts
    // these exclusively through Core's internal, supervised worker job.
    fn publish(c: &Connection, a: &mut GeneratedArtifact) {
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
                unit: Some("ditto-generation-fixture.service".into()),
                cgroup: Some("/fixture/ditto-generation-fixture.service".into()),
                runner_pid: Some(1),
            },
            stages: [
                ValidationStage::Syntax,
                ValidationStage::Contract,
                ValidationStage::Load,
                ValidationStage::Focus,
                ValidationStage::Interaction,
            ]
            .into_iter()
            .map(|stage| StageEvidence {
                stage,
                result: StageResult::Passed,
                diagnostic: String::new(),
            })
            .collect(),
            test_data: true,
            preview_opened: false,
            diagnostics: vec![],
        });
        a.state = ArtifactState::Published;
        save(c, a).unwrap();
    }
    fn document(a: &GeneratedArtifact) -> ProfileDocument {
        let mut doc = crate::profiles::tests::document();
        doc.entries = vec![EntrySpec {
            entry_id: "ent-generated".into(),
            package: a.description.plugin_id.clone(),
            version: a.description.version.clone(),
            host: HostKind::Qml,
            config: json!({}),
            disabled: false,
            area: Some("ui.generated_panel".into()),
        }];
        doc
    }

    fn fail_at(c: &Connection, a: &mut GeneratedArtifact, passed: usize, diagnostic: &str) {
        publish(c, a);
        let mut report = a.validation.take().unwrap();
        for (index, stage) in report.stages.iter_mut().enumerate().skip(passed) {
            stage.result = if index == passed {
                StageResult::Failed
            } else {
                StageResult::NotRun
            };
            stage.diagnostic = diagnostic.into();
        }
        let job = format!("job-{}", a.description.version);
        a.validation_job_id = Some(job.clone());
        a.state = ArtifactState::Validating;
        save(c, a).unwrap();
        *a = validation_finished(c, &a.artifact_id, &job, Some(report), None).unwrap();
    }

    #[test]
    fn changed_diagnostic_without_stage_progress_stops_a_repair() {
        let temp = crate::testing::open("generated-no-progress");
        let c = temp.store.connection();
        let mut a = candidate(c, None, "1.0.0", DataPlan::default());
        a.origin.turn_id = Some("turn-no-progress".into());
        fail_at(c, &mut a, 2, "first load failure");
        assert!(!a.repair.stopped);
        let mut b = candidate(c, Some(&a), "1.0.1", DataPlan::default());
        b.origin = a.origin.clone();
        fail_at(c, &mut b, 2, "different load failure");
        assert!(get(c, &b.artifact_id).unwrap().repair.stopped);
        assert_ne!(
            b.repair.failure_fingerprints[0],
            b.repair.failure_fingerprints[1]
        );
        let input = GenerateInput {
            description: Description {
                version: "1.0.2".into(),
                ..b.description.clone()
            },
            request_summary: "test".into(),
            parent_id: Some(b.artifact_id.clone()),
            idempotency_key: "blocked-repair".into(),
        };
        assert!(create(c, &input, b.origin.clone()).is_err());
        // Reopen the persisted store: neither branching from an older parent
        // nor inventing another plugin id resets this turn's stopped budget.
        let reopened = crate::Store::open_reader(&crate::Paths::under(&temp.root)).unwrap();
        let mut bypass = input.clone();
        bypass.parent_id = Some(a.artifact_id.clone());
        assert!(create(reopened.connection(), &bypass, b.origin.clone()).is_err());
        bypass.parent_id = None;
        bypass.description.plugin_id = "local.generated.budget_bypass".into();
        assert!(create(reopened.connection(), &bypass, b.origin.clone()).is_err());
        // A different failure at an earlier gate is also not progress.
        let mut other = b.origin.clone();
        other.turn_id = Some("new-explicit-request".into());
        let mut fresh = create(c, &input, other).unwrap();
        assert_eq!(fresh.repair.attempts, 0);
        fail_at(c, &mut fresh, 1, "new request contract failure");
        assert!(!fresh.repair.stopped);
        let mut regression = candidate(c, Some(&fresh), "1.0.3", DataPlan::default());
        fail_at(c, &mut regression, 0, "regressed syntax");
        assert!(regression.repair.stopped);
    }
    #[test]
    fn snapshot_migration_rollback_and_optimistic_data_writes_are_atomic() {
        let mut temp = crate::testing::open("generated-migration");
        let c = temp.store.connection();
        let data = DataPlan {
            fields: [("note".into(), DataType::Text)].into(),
            ..Default::default()
        };
        let mut a = candidate(c, None, "1.0.0", data);
        publish(c, &mut a);
        apply_document(c, &document(&a), "first").unwrap();
        let input = GeneratedDataInput {
            artifact_id: a.artifact_id.clone(),
            payload: json!({"note":"keep me"}),
            expected_revision: 1,
        };
        data_write(c, &a, &input).unwrap();
        assert!(data_write(c, &a, &input).is_err());
        let migration = DataMigration {
            from_version: 1,
            rename: [("note".into(), "title".into())].into(),
            defaults: [("done".into(), json!(false))].into(),
            remove: vec![],
            rollback: RollbackPolicy::Snapshot,
        };
        let mut b = candidate(
            c,
            Some(&a),
            "2.0.0",
            DataPlan {
                schema_version: 2,
                fields: [
                    ("title".into(), DataType::Text),
                    ("done".into(), DataType::Boolean),
                ]
                .into(),
                migration: Some(migration),
            },
        );
        publish(c, &mut b);
        // Simulate a failed Profile commit AFTER data migration, in the same tx.
        let failure: StoreResult<()> = temp.store.write(|tx| {
            apply_document(tx, &document(&b), "aborted")?;
            Err(StoreError::Invalid("injected commit failure".into()))
        });
        assert!(failure.is_err());
        let c = temp.store.connection();
        assert_eq!(data_get(c, &a).unwrap().payload, json!({"note":"keep me"}));
        assert_eq!(
            get(c, &b.artifact_id).unwrap().state,
            ArtifactState::Published
        );
        temp.store
            .write(|tx| apply_document(tx, &document(&b), "upgrade"))
            .unwrap();
        let c = temp.store.connection();
        assert_eq!(
            data_get(c, &b).unwrap().payload,
            json!({"title":"keep me","done":false})
        );
        assert!(data_get(c, &a).is_err());
        temp.store
            .write(|tx| apply_document(tx, &document(&a), "rollback"))
            .unwrap();
        let c = temp.store.connection();
        assert_eq!(data_get(c, &a).unwrap().payload, json!({"note":"keep me"}));
        assert!(data_get(c, &b).is_err());
        data_write(
            c,
            &a,
            &GeneratedDataInput {
                artifact_id: a.artifact_id.clone(),
                expected_revision: data_get(c, &a).unwrap().revision,
                payload: json!({"note":"latest snapshot"}),
            },
        )
        .unwrap();
        apply_document(c, &document(&b), "upgrade-two").unwrap();
        // Wall-clock changes cannot make an earlier snapshot win.
        c.execute(
            "UPDATE generated_data_snapshots SET created_at='2999-01-01' WHERE change_id='upgrade'",
            [],
        )
        .unwrap();
        apply_document(c, &document(&a), "rollback-two").unwrap();
        assert_eq!(
            data_get(c, &a).unwrap().payload,
            json!({"note":"latest snapshot"})
        );
    }
    #[test]
    fn compatible_rollback_keeps_current_readable_values_without_a_snapshot() {
        let temp = crate::testing::open("generated-compatible");
        let c = temp.store.connection();
        let fields = [("note".into(), DataType::Text)].into();
        let mut a = candidate(
            c,
            None,
            "1.0.0",
            DataPlan {
                fields,
                ..Default::default()
            },
        );
        publish(c, &mut a);
        apply_document(c, &document(&a), "first").unwrap();
        let mut b = candidate(
            c,
            Some(&a),
            "2.0.0",
            DataPlan {
                schema_version: 2,
                fields: a.description.data.fields.clone(),
                migration: Some(DataMigration {
                    from_version: 1,
                    rename: Default::default(),
                    defaults: Default::default(),
                    remove: vec![],
                    rollback: RollbackPolicy::Compatible,
                }),
            },
        );
        publish(c, &mut b);
        apply_document(c, &document(&b), "upgrade").unwrap();
        data_write(
            c,
            &b,
            &GeneratedDataInput {
                artifact_id: b.artifact_id.clone(),
                expected_revision: data_get(c, &b).unwrap().revision,
                payload: json!({"note":"edited in the new version"}),
            },
        )
        .unwrap();
        apply_document(c, &document(&a), "rollback").unwrap();
        assert_eq!(
            data_get(c, &a).unwrap().payload,
            json!({"note":"edited in the new version"})
        );
        assert_eq!(
            c.query_row("SELECT count(*) FROM generated_data_snapshots", [], |r| r
                .get::<_, i64>(
                0
            ))
            .unwrap(),
            0
        );
    }
    #[test]
    fn irreversible_migration_and_schema_version_reuse_are_refused() {
        let temp = crate::testing::open("generated-irreversible");
        let c = temp.store.connection();
        let mut a = candidate(c, None, "1.0.0", DataPlan::default());
        publish(c, &mut a);
        apply_document(c, &document(&a), "initial").unwrap();
        let mut b = candidate(
            c,
            Some(&a),
            "2.0.0",
            DataPlan {
                schema_version: 2,
                fields: Default::default(),
                migration: Some(DataMigration {
                    from_version: 1,
                    rename: Default::default(),
                    defaults: Default::default(),
                    remove: vec![],
                    rollback: RollbackPolicy::Unavailable,
                }),
            },
        );
        publish(c, &mut b);
        apply_document(c, &document(&b), "upgrade").unwrap();
        assert!(check_document(c, &document(&a)).is_err());
        let mut input = GenerateInput {
            description: b.description.clone(),
            request_summary: "test".into(),
            parent_id: Some(b.artifact_id.clone()),
            idempotency_key: "bad-schema".into(),
        };
        input.description.version = "3.0.0".into();
        input
            .description
            .data
            .fields
            .insert("new".into(), DataType::Text);
        assert!(create(c, &input, b.origin.clone()).is_err());
        input.description.data.fields.clear();
        input.description.version = "1.9.0".into();
        assert!(create(c, &input, b.origin.clone()).is_err());
    }
    #[test]
    fn repeated_failure_stops_repair_and_versions_remain_immutable() {
        let temp = crate::testing::open("generated-repair");
        let c = temp.store.connection();
        let mut a = candidate(c, None, "1.0.0", DataPlan::default());
        a.validation_job_id = Some("job1".into());
        save(c, &a).unwrap();
        let a = validation_finished(c, &a.artifact_id, "job1", None, Some("same error")).unwrap();
        assert!(!a.repair.stopped);
        let mut b = candidate(c, Some(&a), "1.0.1", DataPlan::default());
        assert_eq!(b.repair.attempts, 1);
        b.validation_job_id = Some("job2".into());
        save(c, &b).unwrap();
        let b = validation_finished(c, &b.artifact_id, "job2", None, Some("same error")).unwrap();
        assert!(b.repair.stopped);
        assert_eq!(get(c, &a.artifact_id).unwrap().description.version, "1.0.0");
        let input = GenerateInput {
            description: Description {
                version: "1.0.2".into(),
                ..b.description.clone()
            },
            request_summary: "test".into(),
            parent_id: Some(b.artifact_id.clone()),
            idempotency_key: "third".into(),
        };
        assert!(create(c, &input, b.origin.clone()).is_err());
        let mut explicit = b.origin;
        explicit.turn_id = Some("turn-new-user-request".into());
        let fresh = create(c, &input, explicit).unwrap();
        assert!(!fresh.repair.stopped);
        assert_eq!(fresh.repair.attempts, 0);
    }
    #[test]
    fn different_failures_still_stop_after_three_repairs() {
        let temp = crate::testing::open("generated-repair-limit");
        let c = temp.store.connection();
        let mut a = candidate(c, None, "1.0.0", DataPlan::default());
        for round in 0..=3 {
            fail_at(c, &mut a, round, &format!("error{round}"));
            assert_eq!(a.repair.stopped, round == 3);
            if round < 3 {
                a = candidate(
                    c,
                    Some(&a),
                    &format!("1.0.{}", round + 1),
                    DataPlan::default(),
                );
            }
        }
        assert_eq!(a.repair.attempts, 3);
    }
}
