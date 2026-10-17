//! The ChangeSet coordinator (G1-CORE-03/07/08/11). It owns the only writing
//! store connection and runs every change through the state machine:
//!
//! ```text
//! draft → validated → prepared → applying → verifying → committed
//!   ↓         ↓           ↓          ↓           ↓
//! rejected  aborted    aborted   rolling_back → rolled_back | partially_applied
//! ```
//!
//! Each transition is written before the side effect it announces, each
//! participant call is an `operations` row before it is sent, and success is
//! decided by reading back what participants report, never by their answer.

use std::{
    collections::BinaryHeap,
    path::Path,
    sync::{mpsc::Receiver, Arc},
    time::{Duration, Instant},
};

use ditto_protocol::{
    catalog,
    change::{
        ChangeMode, ChangeOp, ChangeOrigin, ChangeRecord, ChangeState, Confirmation, HotSwapLevel,
        OutcomeItem, OutcomeStatus, PreflightCode,
    },
    ids,
    participant::{
        ChangePhase, ItemStatus, Observation, ParticipantPhase, ParticipantRole, PrepareParams,
        Projection, StateOutput, ORIGIN_BOOT, ORIGIN_CHANGE,
    },
    profile::{HostKind, ProfileDocument, RevisionOrigin},
    services::Grant,
    ConflictReason, DesktopEventPayload, UnavailableReason,
};
use ditto_store::{
    audit::{self, AuditEntry},
    changes::{self, NewChange, NewOperation, StoredChange},
    grants, jobs, packages, profiles, retention, OpenReport, Store, StoreError, StoreResult,
};
use serde_json::{json, Value};

use crate::{
    core::Core,
    defaults, docops,
    error::CoreError,
    fault,
    participants::{
        Participant, ParticipantError, RemoteParticipant, ABORT_TIMEOUT, COMMIT_TIMEOUT,
        PREPARE_TIMEOUT, ROLLBACK_TIMEOUT, STATE_TIMEOUT,
    },
    preflight::{self, Validation},
    projection::{self, PackageSet, Resolver, Verdict},
    sdnotify,
};

/// A change request as the router hands it over. Subject and origin come from
/// the connection, never from the caller's parameters.
#[derive(Clone, Debug)]
pub struct Proposal {
    pub profile_id: Option<String>,
    pub base_revision: String,
    pub ops: Vec<ChangeOp>,
    pub mode: ChangeMode,
    pub idempotency_key: Option<String>,
    pub request_operation_id: Option<String>,
    pub origin: ChangeOrigin,
    pub subject: String,
    /// A whole target document (profile switch, restore, revert) instead of
    /// ops applied to the head.
    pub target: Option<Target>,
}

#[derive(Clone, Debug)]
pub struct Target {
    pub document: ProfileDocument,
    /// Set for a profile switch: this profile becomes active and its
    /// existing revision is what the change commits.
    pub switch_to: Option<(String, String)>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
enum TimerKind {
    ConfirmDeadline,
    Observation,
    HostResync,
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct Timer {
    at: Instant,
    kind: TimerKind,
    subject: String,
    extra: String,
}

impl Ord for Timer {
    fn cmp(&self, other: &Self) -> std::cmp::Ordering {
        other
            .at
            .cmp(&self.at)
            .then_with(|| self.kind.cmp(&other.kind))
            .then_with(|| self.subject.cmp(&other.subject))
    }
}

impl PartialOrd for Timer {
    fn partial_cmp(&self, other: &Self) -> Option<std::cmp::Ordering> {
        Some(self.cmp(other))
    }
}

struct Step {
    role: ParticipantRole,
    participant: Box<dyn Participant>,
    target: Projection,
    base: Projection,
    prepared: bool,
    committed: bool,
}

pub struct Coordinator {
    core: Arc<Core>,
    store: Store,
    open_report: OpenReport,
    timers: BinaryHeap<Timer>,
    last_idle_work: Instant,
    booted: bool,
}

fn role_name(role: ParticipantRole) -> &'static str {
    role.as_str()
}

impl Coordinator {
    pub fn new(core: Arc<Core>, store: Store, open_report: OpenReport) -> Self {
        Self {
            core,
            store,
            open_report,
            timers: BinaryHeap::new(),
            last_idle_work: Instant::now(),
            booted: false,
        }
    }

    // ---- loop -----------------------------------------------------------------

    pub fn run(&mut self, work: Receiver<crate::core::Work>) {
        loop {
            sdnotify::watchdog();
            let wait = self
                .timers
                .peek()
                .map(|timer| timer.at.saturating_duration_since(Instant::now()))
                .unwrap_or(Duration::from_secs(1))
                .min(Duration::from_secs(1));
            match work.recv_timeout(wait) {
                Ok(job) => job(self),
                Err(std::sync::mpsc::RecvTimeoutError::Timeout) => self.idle(),
                Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => return,
            }
            self.fire_timers();
        }
    }

    fn fire_timers(&mut self) {
        while self
            .timers
            .peek()
            .is_some_and(|timer| timer.at <= Instant::now())
        {
            let timer = self.timers.pop().expect("peeked");
            match timer.kind {
                TimerKind::ConfirmDeadline => self.confirm_deadline(&timer.subject),
                TimerKind::Observation => self.observation_end(&timer.subject, &timer.extra),
                TimerKind::HostResync => self.sync_participant(ParticipantRole::Hostd),
            }
        }
    }

    /// Retention runs only while nothing else is queued, and in small steps.
    fn idle(&mut self) {
        if self.last_idle_work.elapsed() < Duration::from_secs(60) {
            return;
        }
        self.last_idle_work = Instant::now();
        match self.store.write(|tx| retention::collect(tx)) {
            Ok(deleted) if !deleted.is_empty() => {
                crate::log::event(
                    "retention.collected",
                    &[("count", &deleted.len().to_string())],
                );
            }
            Ok(_) => {}
            Err(error) => crate::log::event("retention.failed", &[("reason", &error.to_string())]),
        }
    }

    fn schedule(&mut self, after: Duration, kind: TimerKind, subject: &str, extra: &str) {
        self.timers.push(Timer {
            at: Instant::now() + after,
            kind,
            subject: subject.into(),
            extra: extra.into(),
        });
    }

    fn audit(
        &mut self,
        change_id: Option<&str>,
        subject: &str,
        action: &str,
        decision: &str,
        detail: &str,
    ) {
        let detail = crate::log::redact_paths(detail);
        let _ = self.store.write(|tx| {
            audit::append(
                tx,
                &AuditEntry {
                    change_id,
                    subject,
                    action,
                    decision,
                    redacted_detail: &detail,
                    ..Default::default()
                },
            )
        });
    }

    pub fn audit_decision(&mut self, subject: &str, action: &str, decision: &str, detail: &str) {
        self.audit(None, subject, action, decision, detail);
    }

    // ---- boot -------------------------------------------------------------------

    /// First start: built-in packages, the default Profile, recovery of any
    /// change a crash left between states, then the participants.
    pub fn boot(&mut self, builtin: Option<&Path>) {
        let report = self.open_report.clone();
        if let Some(from) = report.migrated_from {
            self.audit(
                None,
                "core",
                "store.migrated",
                "applied",
                &format!("from schema {from}"),
            );
        }
        for partial in &report.removed_partials {
            self.audit(
                None,
                "core",
                "store.partial_removed",
                "applied",
                &partial.display().to_string(),
            );
        }
        match crate::jobs_pool::reap_interrupted(self.store.connection()) {
            Ok(()) => self
                .core
                .jobs
                .recovery_clean
                .store(true, std::sync::atomic::Ordering::SeqCst),
            Err(error) => crate::log::event(
                "jobs.recovery_cleanup_failed",
                &[("reason", &error.to_string())],
            ),
        }
        let _ = self.store.write(|tx| {
            jobs::fail_interrupted(tx)?;
            crate::generation::reconcile(tx)?;
            ditto_store::bindings::expire_generation(tx, None)?;
            Ok(())
        });
        if let Some(directory) = builtin {
            self.seed_builtin(directory);
        }
        if let Err(error) = self.ensure_active_profile() {
            crate::log::event("boot.profile_failed", &[("reason", &error.to_string())]);
        }
        self.refresh_host_needs();
        self.core.shell.launch();
        if self.host_needed() {
            self.core.hosts.ensure_started();
        }
        self.recover();
        // Every in-flight ChangeSet now has its outcome: settle the tool
        // calls whose result was lost with what Core can prove, never by
        // running them again (G2-AGENT-10).
        match ditto_store::turns::reconcile_dispatched(&mut self.store) {
            Ok(0) => {}
            Ok(count) => {
                crate::log::event("agent.tools_reconciled", &[("count", &count.to_string())])
            }
            Err(error) => crate::log::event(
                "agent.tools_reconcile_failed",
                &[("reason", &error.to_string())],
            ),
        }
        self.core.finish_recovery();
        self.booted = true;
        sdnotify::ready();
        // Participants that connected during recovery are synced now.
        if self.core.shell.is_connected() {
            self.sync_participant(ParticipantRole::Shell);
        }
        if self.core.hosts.is_ready() {
            self.sync_participant(ParticipantRole::Hostd);
        }
        self.sync_participant(ParticipantRole::Compositor);
        self.watch_head_for_last_known_good();
    }

    fn seed_builtin(&mut self, directory: &Path) {
        let Ok(entries) = std::fs::read_dir(directory) else {
            crate::log::event(
                "boot.builtin_missing",
                &[("path", &directory.display().to_string())],
            );
            return;
        };
        let mut archives: Vec<_> = entries
            .flatten()
            .map(|entry| entry.path())
            .filter(|path| path.extension().is_some_and(|ext| ext == "dittopkg"))
            .collect();
        archives.sort();
        let paths = self.store.paths().clone();
        for archive in archives {
            let stage = ids::new(ids::JOB);
            match packages::unpack(&paths, &archive, None, &stage) {
                Ok(unpacked) => {
                    if let Err(error) = self
                        .store
                        .write(|tx| packages::insert(tx, &unpacked, "builtin", None))
                    {
                        crate::log::event(
                            "boot.builtin_refused",
                            &[
                                ("package", &unpacked.manifest.id),
                                ("reason", &error.to_string()),
                            ],
                        );
                    }
                }
                Err(error) => crate::log::event(
                    "boot.builtin_refused",
                    &[
                        ("path", &archive.display().to_string()),
                        ("reason", &error.to_string()),
                    ],
                ),
            }
        }
    }

    fn ensure_active_profile(&mut self) -> StoreResult<()> {
        let active = profiles::active_profile(self.store.connection())?;
        if let Some(active) = active {
            if profiles::get(self.store.connection(), &active).is_ok() {
                self.publish_head()?;
                return Ok(());
            }
        }
        let existing = profiles::list(self.store.connection())?;
        let profile_id = match existing.first() {
            Some(profile) => profile.profile_id.clone(),
            None => {
                // Bootstrap only an empty profile store. Never backfill or
                // overwrite user compositions on upgrade, even with no active id.
                let documents = defaults::builtin_documents(&self.packages());
                let origin = RevisionOrigin::Create {
                    from: "default".into(),
                };
                self.store.write(|tx| {
                    let mut first = None;
                    for (name, document) in &documents {
                        let (profile, _) = profiles::create(tx, name, document, &origin)?;
                        first.get_or_insert(profile.profile_id);
                    }
                    let profile_id = first.expect("built-in compositions are nonempty");
                    profiles::set_active_profile(tx, &profile_id)?;
                    Ok(())
                })?;
                return self.publish_head();
            }
        };
        self.store
            .write(|tx| profiles::set_active_profile(tx, &profile_id))?;
        self.publish_head()
    }

    fn publish_head(&mut self) -> StoreResult<()> {
        let (profile, revision, _) = self.active_head()?;
        self.core
            .session
            .set_profile_revision(Some(revision.revision_id.clone()));
        let _ = profile;
        Ok(())
    }

    fn active_head(
        &self,
    ) -> StoreResult<(
        ditto_protocol::profile::ProfileSummary,
        ditto_protocol::profile::RevisionSummary,
        ProfileDocument,
    )> {
        let active = profiles::active_profile(self.store.connection())?
            .ok_or_else(|| StoreError::NotFound("no active profile".into()))?;
        profiles::head_document(self.store.connection(), &active)
    }

    pub fn packages(&self) -> PackageSet {
        let rows = packages::list(self.store.connection()).unwrap_or_default();
        for row in &rows {
            self.core.hosts.remember_manifest(
                &row.summary.package_id,
                row.manifest
                    .provided_capabilities()
                    .map(String::from)
                    .collect(),
                row.manifest.events.clone(),
            );
        }
        PackageSet::new(rows)
    }

    fn grants(&self) -> Vec<Grant> {
        grants::list(self.store.connection(), None, false).unwrap_or_default()
    }

    fn host_needed(&self) -> bool {
        self.active_head()
            .map(|(_, _, document)| {
                document
                    .entries
                    .iter()
                    .any(|entry| entry.host == HostKind::Cordis && !entry.disabled)
            })
            .unwrap_or(false)
    }

    fn refresh_host_needs(&mut self) {
        let needed = self.host_needed() && !self.core.hosts.is_rescue();
        self.core.hosts.set_needed(needed);
        if needed {
            self.core.hosts.ensure_started();
        }
    }

    fn watch_head_for_last_known_good(&mut self) {
        if let Ok((profile, revision, _)) = self.active_head() {
            if profile.last_known_good.is_none() {
                let period = self.core.config.observation_period;
                self.schedule(
                    period,
                    TimerKind::Observation,
                    &revision.revision_id,
                    &format!("{:?}", Instant::now()),
                );
            }
        }
    }

    // ---- participants -------------------------------------------------------------

    fn participant(&self, role: ParticipantRole) -> Result<Box<dyn Participant>, ParticipantError> {
        match role {
            ParticipantRole::Shell => self
                .core
                .shell
                .participant()
                .map(|participant| Box::new(participant) as Box<dyn Participant>)
                .ok_or(ParticipantError::Unavailable),
            ParticipantRole::Hostd => {
                if self.core.hosts.is_rescue() {
                    return Err(ParticipantError::Unavailable);
                }
                if !self.core.hosts.is_ready() {
                    self.core.hosts.ensure_started();
                    if !self
                        .core
                        .hosts
                        .wait_ready(self.core.config.recovery_wait_host)
                    {
                        return Err(ParticipantError::Unavailable);
                    }
                }
                self.core
                    .hosts
                    .peer()
                    .map(|peer| {
                        Box::new(RemoteParticipant::new(ParticipantRole::Hostd, peer))
                            as Box<dyn Participant>
                    })
                    .ok_or(ParticipantError::Unavailable)
            }
            ParticipantRole::Compositor => {
                Ok(Box::new(CompositorHandle(Arc::clone(&self.core))) as Box<dyn Participant>)
            }
        }
    }

    fn resolver_parts(&self) -> (PackageSet, Vec<Grant>) {
        (self.packages(), self.grants())
    }

    /// Push the active head's projection to one participant (boot, reconnect).
    /// Not a ChangeSet: nothing in the Profile changes, the participant is
    /// brought to what is already committed.
    pub fn sync_participant(&mut self, role: ParticipantRole) {
        if !self.booted {
            return;
        }
        let Ok((_, revision, document)) = self.active_head() else {
            return;
        };
        let (packages, grants) = self.resolver_parts();
        let paths = self.store.paths().clone();
        let resolver = Resolver {
            packages: &packages,
            paths: &paths,
            grants: &grants,
        };
        let target = projection::projection(role, &document, &resolver);
        let Ok(participant) = self.participant(role) else {
            return;
        };
        let change_id = format!("boot-{}", ids::ulid());
        if let Projection::Hostd(host) = &target {
            self.core.hosts.stage(&change_id, host);
        }
        let params = PrepareParams {
            change_id: change_id.clone(),
            origin: ORIGIN_BOOT.into(),
            undoes: None,
            target: target.clone(),
        };
        let prepared = participant.prepare(&params, PREPARE_TIMEOUT);
        let failed: Vec<String> = match &prepared {
            Ok(report) => report
                .items
                .iter()
                .filter(|item| item.status != ItemStatus::Ready)
                .map(|item| format!("{}:{}", item.key, item.reason.clone().unwrap_or_default()))
                .collect(),
            Err(error) => vec![error.key().into()],
        };
        if prepared.is_err() {
            if let Projection::Hostd(_) = &target {
                self.core.hosts.discard(&change_id);
            }
            self.audit(
                None,
                "core",
                "participant.sync",
                "failed",
                &format!("{} {}", role_name(role), failed.join(",")),
            );
            return;
        }
        // Items that are not ready are skipped by the participant; the rest
        // of the desktop still comes up (a broken provider must not take
        // the whole Shell down with it).
        if let Projection::Hostd(host) = &target {
            self.core.hosts.activate(&change_id, host);
        }
        let committed = participant.commit(&change_id, COMMIT_TIMEOUT);
        let detail = format!(
            "{} revision={} not_ready=[{}] commit={}",
            role_name(role),
            revision.revision_id,
            failed.join(","),
            committed
                .as_ref()
                .map(|_| "ok".to_string())
                .unwrap_or_else(|error| error.key().into())
        );
        let decision = if committed.is_ok() && failed.is_empty() {
            "applied"
        } else {
            "partial"
        };
        self.audit(None, "core", "participant.sync", decision, &detail);
        crate::log::event(
            "participant.sync",
            &[("role", role_name(role)), ("decision", decision)],
        );
    }

    // ---- proposals ------------------------------------------------------------------

    fn preflight_context<'a>(
        &self,
        head_revision: &'a str,
        base_revision: &'a str,
        packages: &'a PackageSet,
        resolver: &'a Resolver<'a>,
        origin: &'a ChangeOrigin,
        node_version: Option<&'a str>,
    ) -> preflight::Context<'a> {
        preflight::Context {
            head_revision,
            base_revision,
            packages,
            resolver,
            origin,
            session_locked: self.core.session_locked(),
            free_bytes: self.store.free_bytes().ok(),
            node_version,
            verify_trees: self.core.config.verify_trees,
        }
    }

    /// Run a proposal to a terminal state (or pending confirmation).
    /// `accepted` is told the change id as soon as the draft is written.
    pub fn propose(
        &mut self,
        mut proposal: Proposal,
        accepted: Option<std::sync::mpsc::Sender<String>>,
    ) -> Result<ChangeRecord, CoreError> {
        if let [ChangeOp::SwitchProfile {
            to_profile,
            to_revision,
        }] = proposal.ops.as_slice()
        {
            if proposal.target.is_none() {
                // A switch commits the other profile's existing revision; it
                // is a change to the desktop, not an edit of either profile.
                let target_profile = profiles::get(self.store.connection(), to_profile)?;
                let revision_id = to_revision
                    .clone()
                    .unwrap_or(target_profile.head_revision.clone());
                let (summary, document) =
                    profiles::revision(self.store.connection(), &revision_id)?;
                if summary.profile_id != target_profile.profile_id {
                    return Err(CoreError::invalid(
                        "the revision belongs to another profile",
                    ));
                }
                proposal.target = Some(Target {
                    document,
                    switch_to: Some((target_profile.profile_id, revision_id)),
                });
            }
        }
        if let Some(key) = &proposal.idempotency_key {
            if let Some(existing) = changes::by_idempotency_key(self.store.connection(), key)? {
                if let Some(accepted) = &accepted {
                    let _ = accepted.send(existing.record.change_id.clone());
                }
                return Ok(existing.record);
            }
        }
        let profile_id = match &proposal.profile_id {
            Some(id) => id.clone(),
            None => profiles::active_profile(self.store.connection())?
                .ok_or_else(|| CoreError::not_found("no active profile"))?,
        };
        let (profile, head, head_document) =
            profiles::head_document(self.store.connection(), &profile_id)?;
        let (packages, grants) = self.resolver_parts();
        let paths = self.store.paths().clone();
        let resolver = Resolver {
            packages: &packages,
            paths: &paths,
            grants: &grants,
        };
        let node = self.core.hosts.node_version();
        let context = self.preflight_context(
            &head.revision_id,
            &proposal.base_revision,
            &packages,
            &resolver,
            &proposal.origin,
            node.as_deref(),
        );
        let mut validation = match &proposal.target {
            Some(target) => preflight::run_target(
                &head_document,
                target.document.clone(),
                proposal.ops.clone(),
                &context,
            ),
            None => preflight::run(&head_document, &proposal.ops, &context),
        };
        if let Err(error) =
            ditto_store::generated::check_document(self.store.connection(), &validation.target)
        {
            validation.reasons.push(docops::reason(
                PreflightCode::PreconditionFailed,
                None,
                json!({"why":"generated_data_policy","detail":error.to_string()}),
            ));
        }
        // A generic config grant must not silently migrate plugin data. Agent
        // activation carries a durable, authorized development intent instead.
        if proposal.subject == "agent" || proposal.subject.starts_with("agent.") {
            let changed_schema = validation.target.entries.iter().filter(|e| !e.disabled).any(|entry| {
                let next=ditto_store::generated::by_package(self.store.connection(), &entry.package, &entry.version).ok().flatten();
                let old_id=self.store.connection().query_row("SELECT artifact_id FROM generated_plugin_data WHERE plugin_id=?1",[&entry.package],|r|r.get::<_,String>(0)).ok();
                let previous=old_id.and_then(|id|ditto_store::generated::get(self.store.connection(),&id).ok());
                matches!((previous,next),(Some(a),Some(b)) if a.description.data != b.description.data)
            });
            let authorized = match &proposal.origin {
                ChangeOrigin::Agent{turn_id,tool_call_id,..} => self.store.connection().query_row(
                    "SELECT EXISTS(SELECT 1 FROM agent_tool_intents WHERE turn_id=?1 AND call_id=?2 AND capability_id=?3)",
                    rusqlite::params![turn_id,tool_call_id,ditto_protocol::catalog::DEVELOPMENT_ACTIVATE], |r|r.get::<_,bool>(0)).unwrap_or(false),
                _ => false,
            };
            if changed_schema && !authorized {
                validation.reasons.push(docops::reason(
                    PreflightCode::PermissionRequired,
                    None,
                    json!({"why":"generated_data_requires_development_activation"}),
                ));
            }
        }
        let stored = self.store.write(|tx| {
            changes::insert(
                tx,
                &NewChange {
                    profile_id: &profile.profile_id,
                    base_revision: &proposal.base_revision,
                    ops: &validation.ops,
                    mode: proposal.mode,
                    origin: &proposal.origin,
                    subject: &proposal.subject,
                    idempotency_key: proposal.idempotency_key.as_deref(),
                    request_operation_id: proposal.request_operation_id.as_deref(),
                    card: &validation.card,
                    hot_swap_level: validation.level,
                },
            )
        })?;
        let change_id = stored.record.change_id.clone();
        if let Some(accepted) = &accepted {
            let _ = accepted.send(change_id.clone());
        }
        crate::log::event(
            "change.draft",
            &[("change_id", &change_id), ("subject", &proposal.subject)],
        );
        if !validation.reasons.is_empty() {
            self.store.write(|tx| {
                changes::set_reasons(tx, &change_id, &validation.reasons)?;
                changes::transition(tx, &change_id, ChangeState::Draft, ChangeState::Rejected)
            })?;
            self.audit(
                Some(&change_id),
                &proposal.subject,
                "change.preflight",
                "rejected",
                &format!("{} reasons", validation.reasons.len()),
            );
            let record = self.record(&change_id)?;
            self.announce(&record);
            return Ok(record);
        }
        let target_profile = proposal
            .target
            .as_ref()
            .and_then(|target| target.switch_to.clone());
        self.store.write(|tx| {
            changes::set_validation(
                tx,
                &change_id,
                &validation.ops,
                &validation.card,
                validation.level,
                Some(&validation.target),
                target_profile.as_ref().map(|(profile, _)| profile.as_str()),
            )?;
            changes::transition(tx, &change_id, ChangeState::Draft, ChangeState::Validated)
        })?;
        self.execute(
            &change_id,
            &head_document,
            validation,
            proposal.mode,
            target_profile,
        )
    }

    fn record(&self, change_id: &str) -> StoreResult<ChangeRecord> {
        Ok(changes::get(self.store.connection(), change_id)?.record)
    }

    fn announce(&mut self, record: &ChangeRecord) {
        if let Err(error) = self
            .store
            .write(|tx| ditto_store::generated::record_activation(tx, record))
        {
            crate::log::event(
                "generation.journal_failed",
                &[
                    ("change_id", &record.change_id),
                    ("reason", &error.to_string()),
                ],
            );
        }
        self.core.publish(DesktopEventPayload::ChangeUpdated {
            change: Box::new(record.summary()),
        });
    }

    fn operation(
        &mut self,
        change_id: &str,
        role: ParticipantRole,
        step: &str,
        request: &Value,
    ) -> Option<String> {
        self.store
            .write(|tx| {
                changes::start_operation(
                    tx,
                    &NewOperation {
                        change_id,
                        participant: role_name(role),
                        step,
                        request,
                    },
                )
            })
            .ok()
    }

    fn finish(&mut self, operation: Option<String>, state: &str, readback: Option<&Value>) {
        if let Some(operation) = operation {
            let _ = self
                .store
                .write(|tx| changes::finish_operation(tx, &operation, state, readback));
        }
    }

    fn transition(
        &mut self,
        change_id: &str,
        from: ChangeState,
        to: ChangeState,
    ) -> StoreResult<()> {
        self.store
            .write(|tx| changes::transition(tx, change_id, from, to))?;
        if let Ok(record) = self.record(change_id) {
            self.announce(&record);
        }
        Ok(())
    }

    /// The hot-swap executor: prepare every touched participant, commit,
    /// read back, and commit the revision or roll back.
    fn execute(
        &mut self,
        change_id: &str,
        base_document: &ProfileDocument,
        validation: Validation,
        mode: ChangeMode,
        switch_to: Option<(String, String)>,
    ) -> Result<ChangeRecord, CoreError> {
        let stored = changes::get(self.store.connection(), change_id)?;
        let profile_id = stored.record.profile_id.clone();
        // Re-check the base inside the coordinator: another change may have
        // committed since this one was validated (L-09).
        let (_, head, _) = profiles::head_document(self.store.connection(), &profile_id)?;
        if head.revision_id != stored.record.base_revision {
            let reasons = vec![docops::reason(
                PreflightCode::BaseRevisionStale,
                None,
                json!({"base_revision": stored.record.base_revision, "head_revision": head.revision_id}),
            )];
            self.store.write(|tx| {
                changes::set_reasons(tx, change_id, &reasons)?;
                changes::transition(tx, change_id, ChangeState::Validated, ChangeState::Rejected)
            })?;
            let record = self.record(change_id)?;
            self.announce(&record);
            return Ok(record);
        }
        if validation.level == HotSwapLevel::SessionRestart {
            return self.defer_to_next_login(change_id, &validation, switch_to);
        }
        let (packages, grants) = self.resolver_parts();
        let paths = self.store.paths().clone();
        let resolver = Resolver {
            packages: &packages,
            paths: &paths,
            grants: &grants,
        };
        let mut steps = Vec::new();
        let mut items = Vec::new();
        for role in &validation.touched {
            let target = projection::projection(*role, &validation.target, &resolver);
            let base = projection::projection(*role, base_document, &resolver);
            let nothing_to_run =
                matches!(&target, Projection::Hostd(host) if host.entries.is_empty());
            if nothing_to_run && !self.core.hosts.is_ready() {
                // Removing every service needs no running host: there is
                // nothing left for it to stop.
                items.push(outcome(
                    0,
                    *role,
                    "hostd",
                    OutcomeStatus::Applied,
                    Some("host_not_running"),
                ));
                continue;
            }
            match self.participant(*role) {
                Ok(participant) => steps.push(Step {
                    role: *role,
                    participant,
                    target,
                    base,
                    prepared: false,
                    committed: false,
                }),
                Err(error) => {
                    if *role == ParticipantRole::Hostd && self.core.hosts.is_rescue() {
                        // Rescue mode: the Cordis part is recorded for when
                        // the normal mode returns, not failed and not faked.
                        items.push(outcome(
                            0,
                            *role,
                            "hostd",
                            OutcomeStatus::Scheduled,
                            Some("rescue_mode"),
                        ));
                        continue;
                    }
                    items.push(outcome(
                        0,
                        *role,
                        role_name(*role),
                        OutcomeStatus::Failed,
                        Some(error.key()),
                    ));
                    return self.abort(
                        change_id,
                        &mut steps,
                        items,
                        "change.participant_unavailable",
                    );
                }
            }
        }
        let undoes = match &stored.record.origin {
            ChangeOrigin::Undo { undoes } => Some(undoes.clone()),
            ChangeOrigin::TimedRevert { reverts } => Some(reverts.clone()),
            _ => None,
        };
        // prepare
        for step in steps.iter_mut() {
            if let Projection::Hostd(host) = &step.target {
                self.core.hosts.stage(change_id, host);
            }
            let params = PrepareParams {
                change_id: change_id.into(),
                origin: ORIGIN_CHANGE.into(),
                target: step.target.clone(),
                undoes: undoes.clone(),
            };
            let operation = self.operation(change_id, step.role, "prepare", &json!(params));
            sdnotify::watchdog();
            match step.participant.prepare(&params, PREPARE_TIMEOUT) {
                Ok(report) => {
                    step.prepared = true;
                    let mut ready = true;
                    for item in &report.items {
                        if item.status != ItemStatus::Ready {
                            ready = false;
                            let reason = match item.status {
                                ItemStatus::Pending => {
                                    format!("dependency_not_ready: {}", item.missing.join(", "))
                                }
                                _ => item.reason.clone().unwrap_or_else(|| "not ready".into()),
                            };
                            items.push(outcome(
                                0,
                                step.role,
                                &item.key,
                                OutcomeStatus::Failed,
                                Some(&reason),
                            ));
                        }
                    }
                    self.finish(
                        operation,
                        if ready { "succeeded" } else { "failed" },
                        Some(&json!(report)),
                    );
                    if !ready {
                        return self.abort(
                            change_id,
                            &mut steps,
                            items,
                            "change.candidate_not_ready",
                        );
                    }
                }
                Err(error) => {
                    self.finish(operation, "failed", Some(&json!({"error": error.key()})));
                    items.push(outcome(
                        0,
                        step.role,
                        role_name(step.role),
                        OutcomeStatus::Failed,
                        Some(error.key()),
                    ));
                    return self.abort(change_id, &mut steps, items, "change.prepare_failed");
                }
            }
        }
        self.snapshot_plugin_data(change_id, base_document, &validation.target);
        self.transition(change_id, ChangeState::Validated, ChangeState::Prepared)?;
        fault::hit("coordinator.after_state=prepared");
        // A participant whose connection ended after it prepared has applied
        // nothing yet, and its candidates died with it: the change is aborted
        // before anything is committed, not rolled back (L-05).
        let lost: Vec<ParticipantRole> = steps
            .iter()
            .filter(|step| !step.participant.connected())
            .map(|step| step.role)
            .collect();
        if !lost.is_empty() {
            for role in lost {
                items.push(outcome(
                    0,
                    role,
                    role_name(role),
                    OutcomeStatus::Failed,
                    Some(ParticipantError::Disconnected.key()),
                ));
            }
            return self.abort_from(
                change_id,
                ChangeState::Prepared,
                &mut steps,
                items,
                "change.participant_lost",
            );
        }
        self.transition(change_id, ChangeState::Prepared, ChangeState::Applying)?;
        fault::hit("coordinator.after_state=applying");
        // commit
        let mut commit_failed = None;
        for step in steps.iter_mut() {
            if let Projection::Hostd(host) = &step.target {
                for entry_id in self.core.hosts.activate(change_id, host) {
                    self.core.close_subscriptions_of(
                        &ditto_protocol::Subject::host(&entry_id),
                        "entry_removed",
                    );
                }
            }
            let operation = self.operation(
                change_id,
                step.role,
                "commit",
                &json!({"change_id": change_id}),
            );
            sdnotify::watchdog();
            match step.participant.commit(change_id, COMMIT_TIMEOUT) {
                Ok(report) => {
                    step.committed = true;
                    let failed: Vec<_> = report
                        .items
                        .iter()
                        .filter(|item| item.status == ItemStatus::Failed)
                        .collect();
                    self.finish(
                        operation,
                        if failed.is_empty() {
                            "succeeded"
                        } else {
                            "failed"
                        },
                        Some(&json!(report)),
                    );
                    for item in &failed {
                        items.push(outcome(
                            0,
                            step.role,
                            &item.key,
                            OutcomeStatus::Failed,
                            item.reason.as_deref(),
                        ));
                    }
                    // What an undo could not put back (a window closed since
                    // the change) is listed; the change still commits, and
                    // its result is partial (protocol 0.2 §8.2).
                    for item in report
                        .items
                        .iter()
                        .filter(|item| item.status == ItemStatus::NotRestored)
                    {
                        items.push(outcome(
                            0,
                            step.role,
                            &item.key,
                            OutcomeStatus::NotRestored,
                            item.reason.as_deref(),
                        ));
                    }
                    if !failed.is_empty() {
                        commit_failed = Some("change.commit_failed");
                        break;
                    }
                }
                Err(error) => {
                    // A lost connection during commit leaves the effect
                    // unknown: the readback during rollback decides.
                    step.committed = true;
                    self.finish(
                        operation,
                        if error == ParticipantError::Disconnected {
                            "unknown"
                        } else {
                            "failed"
                        },
                        None,
                    );
                    items.push(outcome(
                        0,
                        step.role,
                        role_name(step.role),
                        OutcomeStatus::Failed,
                        Some(error.key()),
                    ));
                    commit_failed = Some("change.commit_failed");
                    break;
                }
            }
        }
        if let Some(key) = commit_failed {
            self.transition(change_id, ChangeState::Applying, ChangeState::RollingBack)?;
            return self.roll_back(change_id, &mut steps, items, key);
        }
        self.transition(change_id, ChangeState::Applying, ChangeState::Verifying)?;
        fault::hit("coordinator.after_state=verifying");
        // readback
        let mut mismatches = Vec::new();
        for step in &steps {
            let verdicts = self.read_back(change_id, step.role, &*step.participant, &step.target);
            for verdict in verdicts {
                if verdict.ok {
                    items.push(outcome(
                        0,
                        step.role,
                        &verdict.key,
                        OutcomeStatus::Applied,
                        None,
                    ));
                } else {
                    mismatches.push(verdict.clone());
                    items.push(outcome(
                        0,
                        step.role,
                        &verdict.key,
                        OutcomeStatus::Failed,
                        verdict.reason.as_deref(),
                    ));
                }
            }
        }
        if fault::take("coordinator.readback=mismatch").is_some() {
            mismatches.push(Verdict {
                key: "injected".into(),
                ok: false,
                reason: Some("injected readback mismatch".into()),
            });
        }
        if !mismatches.is_empty() {
            self.transition(change_id, ChangeState::Verifying, ChangeState::RollingBack)?;
            items.retain(|item| item.status != OutcomeStatus::Applied);
            return self.roll_back(change_id, &mut steps, items, "change.readback_mismatch");
        }
        self.commit_revision(change_id, &validation, mode, switch_to, items)
    }

    fn read_back(
        &mut self,
        change_id: &str,
        role: ParticipantRole,
        participant: &dyn Participant,
        target: &Projection,
    ) -> Vec<Verdict> {
        let deadline = Instant::now() + Duration::from_secs(3);
        loop {
            let operation = self.operation(change_id, role, "readback", &json!({}));
            let observed = participant.state(Some(change_id), STATE_TIMEOUT);
            if let Ok(StateOutput {
                change:
                    Some(ChangePhase {
                        phase: ParticipantPhase::Unknown,
                        ..
                    }),
                ..
            }) = &observed
            {
                // A restarted participant does not remember the change; only
                // what it observes now counts.
                crate::log::event(
                    "participant.change_unknown",
                    &[("change_id", change_id), ("role", role_name(role))],
                );
            }
            let verdicts = match (&observed, target) {
                (Ok(state), _) => self.judge(&state.observed, target),
                (Err(error), _) => vec![Verdict {
                    key: role_name(role).into(),
                    ok: false,
                    reason: Some(error.key().into()),
                }],
            };
            let ok = verdicts.iter().all(|verdict| verdict.ok);
            self.finish(
                operation,
                if ok { "succeeded" } else { "failed" },
                observed.as_ref().ok().map(|state| json!(state)).as_ref(),
            );
            // Registrations and mount reports may trail the commit answer by
            // a moment; a mismatch is final only after a bounded wait.
            if ok || Instant::now() >= deadline || observed.is_err() {
                return verdicts;
            }
            std::thread::sleep(Duration::from_millis(100));
        }
    }

    fn judge(&self, observed: &Observation, target: &Projection) -> Vec<Verdict> {
        match (observed, target) {
            (Observation::Shell(observed), Projection::Shell(target)) => {
                let connected = self
                    .core
                    .session
                    .with_adapter(|adapter| adapter.outputs())
                    .ok()
                    .map(|outputs| {
                        outputs
                            .into_iter()
                            .filter(|output| output.enabled)
                            .map(|output| output.name)
                            .collect::<Vec<_>>()
                    });
                projection::check_shell(target, observed, connected.as_deref())
            }
            (Observation::Hostd(observed), Projection::Hostd(target)) => {
                let hosts = Arc::clone(&self.core.hosts);
                projection::check_host(target, observed, &move |entry| hosts.leases_of(entry))
            }
            (Observation::Compositor(observed), Projection::Compositor(target)) => {
                let strategy = target
                    .strategy
                    .as_deref()
                    .and_then(crate::participants::strategy_name)
                    .is_some_and(|name| {
                        self.core
                            .session
                            .with_adapter(|adapter| Ok(adapter.supports_layout_strategy(name)))
                            .unwrap_or(false)
                    });
                let shortcuts = self
                    .core
                    .session
                    .with_adapter(|adapter| Ok(adapter.supports_shortcut_binding()))
                    .unwrap_or(false);
                projection::check_compositor(target, observed, strategy, shortcuts)
            }
            _ => vec![Verdict {
                key: "observation".into(),
                ok: false,
                reason: Some("the participant answered for a different role".into()),
            }],
        }
    }

    fn abort(
        &mut self,
        change_id: &str,
        steps: &mut [Step],
        items: Vec<OutcomeItem>,
        key: &str,
    ) -> Result<ChangeRecord, CoreError> {
        self.abort_from(change_id, ChangeState::Validated, steps, items, key)
    }

    /// Abort from `from` (validated, or prepared when a participant was lost
    /// before commit): every prepared participant drops its candidates.
    fn abort_from(
        &mut self,
        change_id: &str,
        from: ChangeState,
        steps: &mut [Step],
        items: Vec<OutcomeItem>,
        key: &str,
    ) -> Result<ChangeRecord, CoreError> {
        for step in steps.iter_mut() {
            if step.role == ParticipantRole::Hostd {
                self.core.hosts.discard(change_id);
            }
            if !step.prepared {
                continue;
            }
            let operation = self.operation(
                change_id,
                step.role,
                "abort",
                &json!({"change_id": change_id}),
            );
            let result = step.participant.abort(change_id, ABORT_TIMEOUT);
            self.finish(
                operation,
                if result.is_ok() {
                    "succeeded"
                } else {
                    "failed"
                },
                None,
            );
        }
        self.store.write(|tx| {
            changes::set_items(tx, change_id, &items)?;
            changes::set_failure(tx, change_id, key)?;
            changes::transition(tx, change_id, from, ChangeState::Aborted)
        })?;
        let record = self.record(change_id)?;
        self.audit(Some(change_id), "core", "change.abort", "aborted", key);
        self.announce(&record);
        Ok(record)
    }

    /// Restore every committed participant, then read back against the base.
    /// All restored → rolled_back; anything not restored → partially_applied,
    /// with every item listed.
    fn roll_back(
        &mut self,
        change_id: &str,
        steps: &mut [Step],
        mut items: Vec<OutcomeItem>,
        key: &str,
    ) -> Result<ChangeRecord, CoreError> {
        let mut not_restored = false;
        for step in steps.iter_mut() {
            if !step.committed {
                if step.prepared {
                    let _ = step.participant.abort(change_id, ABORT_TIMEOUT);
                }
                if step.role == ParticipantRole::Hostd {
                    self.core.hosts.discard(change_id);
                }
                continue;
            }
            if let Projection::Hostd(host) = &step.base {
                self.core.hosts.activate(change_id, host);
            }
            let operation = self.operation(
                change_id,
                step.role,
                "rollback",
                &json!({"change_id": change_id}),
            );
            sdnotify::watchdog();
            let report = step.participant.rollback(change_id, ROLLBACK_TIMEOUT);
            self.finish(
                operation,
                if report.is_ok() {
                    "succeeded"
                } else {
                    "failed"
                },
                report.as_ref().ok().map(|r| json!(r)).as_ref(),
            );
            if !step.participant.connected() && step.role == ParticipantRole::Hostd {
                // hostd went away during the change. A restarted hostd keeps
                // nothing on disk and remembers no change, so the committed
                // head (still the base) is pushed to it the way any reconnect
                // is, and the readback below asks it about this change: it
                // answers that it does not know it, and what it runs decides
                // (L-06). Nothing it ran before is replayed.
                if let Ok(replacement) = self.participant(step.role) {
                    self.sync_participant(step.role);
                    step.participant = replacement;
                }
            }
            if let Ok(report) = &report {
                for item in &report.items {
                    if item.status == ItemStatus::NotRestored {
                        not_restored = true;
                        items.push(outcome(
                            0,
                            step.role,
                            &item.key,
                            OutcomeStatus::NotRestored,
                            item.reason.as_deref(),
                        ));
                    }
                }
            }
            let base = step.base.clone();
            let verdicts = self.read_back(change_id, step.role, &*step.participant, &base);
            for verdict in verdicts {
                if verdict.ok {
                    items.push(outcome(
                        0,
                        step.role,
                        &verdict.key,
                        OutcomeStatus::Restored,
                        None,
                    ));
                } else {
                    not_restored = true;
                    items.push(outcome(
                        0,
                        step.role,
                        &verdict.key,
                        OutcomeStatus::NotRestored,
                        verdict.reason.as_deref(),
                    ));
                }
            }
        }
        let terminal = if not_restored {
            ChangeState::PartiallyApplied
        } else {
            ChangeState::RolledBack
        };
        self.store.write(|tx| {
            changes::set_items(tx, change_id, &items)?;
            changes::set_failure(tx, change_id, key)?;
            changes::transition(tx, change_id, ChangeState::RollingBack, terminal)
        })?;
        let record = self.record(change_id)?;
        self.audit(
            Some(change_id),
            "core",
            "change.rollback",
            terminal.as_str(),
            key,
        );
        self.announce(&record);
        Ok(record)
    }

    /// The only place a head moves after a change: new revision and head in
    /// one transaction, so a full disk or an I/O error leaves both as they
    /// were and the change is rolled back instead.
    fn commit_revision(
        &mut self,
        change_id: &str,
        validation: &Validation,
        mode: ChangeMode,
        switch_to: Option<(String, String)>,
        items: Vec<OutcomeItem>,
    ) -> Result<ChangeRecord, CoreError> {
        let stored = changes::get(self.store.connection(), change_id)?;
        let needs_confirmation = mode == ChangeMode::Preview
            || requires_timed_revert(&stored.record.ops, &stored.record);
        let window = self.core.config.confirmation_window;
        fault::before_commit_revision();
        let written = self.store.write(|tx| {
            ditto_store::generated::apply_document(tx, &validation.target, change_id)?;
            let revision_id = match &switch_to {
                Some((profile, revision)) => {
                    profiles::set_active_profile(tx, profile)?;
                    revision.clone()
                }
                None => {
                    let revision = profiles::insert_revision(
                        tx,
                        &stored.record.profile_id,
                        Some(&stored.record.base_revision),
                        &validation.target,
                        &RevisionOrigin::Change {
                            change_id: change_id.into(),
                        },
                        Some(change_id),
                    )?;
                    profiles::set_head(tx, &stored.record.profile_id, &revision.revision_id)?;
                    revision.revision_id
                }
            };
            if needs_confirmation {
                profiles::set_pending_confirmation(tx, &revision_id, true)?;
                changes::set_confirmation(
                    tx,
                    change_id,
                    &Confirmation::Pending {
                        deadline: ditto_store::time::format_unix_millis(
                            ditto_store::time::unix_millis_now() + window.as_millis() as i64,
                        ),
                    },
                )?;
            }
            changes::set_items(tx, change_id, &items)?;
            changes::set_committed_revision(tx, change_id, &revision_id)?;
            changes::transition(
                tx,
                change_id,
                ChangeState::Verifying,
                ChangeState::Committed,
            )?;
            changes::settle_committed_result(tx, change_id)?;
            ditto_store::generated::record_activation(tx, &changes::get(tx, change_id)?.record)?;
            Ok(revision_id)
        });
        let revision_id = match written {
            Ok(revision_id) => revision_id,
            Err(error) => {
                // Nothing was written: head and last-known-good are intact.
                // Put the participants back and report why.
                crate::log::event(
                    "change.commit_write_failed",
                    &[("change_id", change_id), ("reason", &error.to_string())],
                );
                self.transition(change_id, ChangeState::Verifying, ChangeState::RollingBack)?;
                let base_document =
                    profiles::revision(self.store.connection(), &stored.record.base_revision)?.1;
                let mut steps =
                    self.rebuild_steps(&validation.touched, &base_document, &validation.target);
                for step in &mut steps {
                    step.prepared = true;
                    step.committed = true;
                }
                let key = match error {
                    StoreError::StorageFull => "change.storage_full",
                    _ => "change.storage_error",
                };
                return self.roll_back(change_id, &mut steps, items, key);
            }
        };
        self.core
            .session
            .set_profile_revision(Some(revision_id.clone()));
        let record = self.record(change_id)?;
        self.announce(&record);
        self.core.publish(DesktopEventPayload::ProfileChanged {
            profile_id: switch_to
                .as_ref()
                .map(|(profile, _)| profile.clone())
                .unwrap_or(record.profile_id.clone()),
            head_revision: revision_id.clone(),
            active: true,
        });
        self.audit(
            Some(change_id),
            &stored.subject,
            "change.commit",
            "committed",
            &revision_id,
        );
        if needs_confirmation {
            self.schedule(window, TimerKind::ConfirmDeadline, change_id, "");
        }
        let period = self.core.config.observation_period;
        self.schedule(period, TimerKind::Observation, &revision_id, change_id);
        self.refresh_host_needs();
        Ok(record)
    }

    fn rebuild_steps(
        &self,
        roles: &[ParticipantRole],
        base: &ProfileDocument,
        target: &ProfileDocument,
    ) -> Vec<Step> {
        let (packages, grants) = self.resolver_parts();
        let paths = self.store.paths().clone();
        let resolver = Resolver {
            packages: &packages,
            paths: &paths,
            grants: &grants,
        };
        roles
            .iter()
            .filter_map(|role| {
                let participant = self.participant(*role).ok()?;
                Some(Step {
                    role: *role,
                    participant,
                    target: projection::projection(*role, target, &resolver),
                    base: projection::projection(*role, base, &resolver),
                    prepared: false,
                    committed: false,
                })
            })
            .collect()
    }

    /// Session-restart level: nothing is applied now. The revision is saved
    /// so the next login mounts it, and every item says so; the card's
    /// footnote tells the Shell to present it as "applies at next login".
    fn defer_to_next_login(
        &mut self,
        change_id: &str,
        validation: &Validation,
        switch_to: Option<(String, String)>,
    ) -> Result<ChangeRecord, CoreError> {
        self.transition(change_id, ChangeState::Validated, ChangeState::Prepared)?;
        self.transition(change_id, ChangeState::Prepared, ChangeState::Applying)?;
        self.transition(change_id, ChangeState::Applying, ChangeState::Verifying)?;
        let items: Vec<OutcomeItem> = validation
            .touched
            .iter()
            .map(|role| {
                outcome(
                    0,
                    *role,
                    role_name(*role),
                    OutcomeStatus::Scheduled,
                    Some("next_login"),
                )
            })
            .collect();
        self.commit_revision(change_id, validation, ChangeMode::Apply, switch_to, items)
    }

    /// Copy plugin data of cordis entries this change replaces or removes, so
    /// a rollback of their data is possible (CHG-02). `.partial` first, then
    /// rename: an interrupted copy is removed at the next start.
    fn snapshot_plugin_data(
        &mut self,
        change_id: &str,
        base: &ProfileDocument,
        target: &ProfileDocument,
    ) {
        for entry_id in docops::changed_entries(base, target) {
            let Some(entry) = base.entry(&entry_id) else {
                continue;
            };
            if entry.host != HostKind::Cordis {
                continue;
            }
            let source = self.store.paths().plugin_data(&entry.package);
            if !source.exists() {
                continue;
            }
            let snapshot_id = ids::new(ids::SNAPSHOT);
            let partial = self
                .store
                .paths()
                .snapshots()
                .join(format!("{snapshot_id}.partial"));
            let finished = self.store.paths().snapshots().join(&snapshot_id);
            let restorable = copy_tree(&source, &partial)
                .and_then(|()| std::fs::rename(&partial, &finished))
                .is_ok();
            if !restorable {
                let _ = std::fs::remove_dir_all(&partial);
            }
            let path = finished.display().to_string();
            let _ = self.store.write(|tx| {
                tx.execute(
                    "INSERT INTO snapshots (snapshot_id, change_id, scope, data_version, path, restorable, created_at)
                     VALUES (?1, ?2, ?3, NULL, ?4, ?5, ?6)",
                    rusqlite::params![snapshot_id, change_id, format!("plugin-data:{}", entry.package), path, restorable, ditto_store::time::now()],
                )?;
                Ok(())
            });
        }
    }

    // ---- confirmation, observation, undo ----------------------------------------

    pub fn confirm(&mut self, change_id: &str) -> Result<ChangeRecord, CoreError> {
        let stored = changes::get(self.store.connection(), change_id)?;
        match &stored.record.confirmation {
            Confirmation::Pending { .. } => {
                let revision = stored.record.committed_revision.clone().unwrap_or_default();
                self.store.write(|tx| {
                    profiles::set_pending_confirmation(tx, &revision, false)?;
                    changes::set_confirmation(
                        tx,
                        change_id,
                        &Confirmation::Confirmed {
                            at: ditto_store::time::now(),
                        },
                    )
                })?;
            }
            Confirmation::Confirmed { .. } | Confirmation::NotRequired => {}
            Confirmation::Reverted { .. } => {
                return Err(CoreError::conflict(
                    ConflictReason::AlreadyTerminal,
                    "the change was already reverted",
                ))
            }
        }
        let record = self.record(change_id)?;
        self.announce(&record);
        Ok(record)
    }

    /// The countdown lapsed without a confirmation: revert automatically. The
    /// countdown runs here, so a Shell that died mid-countdown changes nothing.
    fn confirm_deadline(&mut self, change_id: &str) {
        let Ok(stored) = changes::get(self.store.connection(), change_id) else {
            return;
        };
        if !matches!(stored.record.confirmation, Confirmation::Pending { .. }) {
            return;
        }
        let outcome = self.revert(
            &stored,
            ChangeOrigin::TimedRevert {
                reverts: change_id.into(),
            },
        );
        match outcome {
            Ok(record) => {
                let _ = self.store.write(|tx| {
                    if let Some(revision) = &stored.record.committed_revision {
                        profiles::set_pending_confirmation(tx, revision, false)?;
                    }
                    changes::set_confirmation(
                        tx,
                        change_id,
                        &Confirmation::Reverted {
                            by_change: record.change_id.clone(),
                        },
                    )
                });
                if let Ok(original) = self.record(change_id) {
                    self.announce(&original);
                }
            }
            Err(error) => crate::log::event(
                "change.timed_revert_failed",
                &[("change_id", change_id), ("reason", &error.message)],
            ),
        }
    }

    /// Cancel before or during a pending confirmation. A change already past
    /// `prepared` cannot be stopped midway; it finishes or rolls back.
    pub fn cancel(&mut self, change_id: &str) -> Result<ChangeRecord, CoreError> {
        let stored = changes::get(self.store.connection(), change_id)?;
        if matches!(stored.record.confirmation, Confirmation::Pending { .. }) {
            self.confirm_deadline(change_id);
            return Ok(self.record(change_id)?);
        }
        match stored.record.state {
            ChangeState::Draft | ChangeState::Validated => {
                self.transition(
                    change_id,
                    stored.record.state,
                    if stored.record.state == ChangeState::Draft {
                        ChangeState::Rejected
                    } else {
                        ChangeState::Aborted
                    },
                )?;
                Ok(self.record(change_id)?)
            }
            state if state.is_terminal() => Err(CoreError::conflict(
                ConflictReason::AlreadyTerminal,
                "the change already finished",
            )),
            _ => Err(CoreError::conflict(
                ConflictReason::ChangeInProgress,
                "the change is being applied and cannot be stopped midway",
            )),
        }
    }

    fn revert(
        &mut self,
        stored: &StoredChange,
        origin: ChangeOrigin,
    ) -> Result<ChangeRecord, CoreError> {
        let (_, head, head_document) =
            profiles::head_document(self.store.connection(), &stored.record.profile_id)?;
        let (_, base_document) =
            profiles::revision(self.store.connection(), &stored.record.base_revision)?;
        let ops = docops::ops_between(&head_document, &base_document);
        self.propose(
            Proposal {
                profile_id: Some(stored.record.profile_id.clone()),
                base_revision: head.revision_id,
                ops: ops.clone(),
                mode: ChangeMode::Apply,
                idempotency_key: None,
                request_operation_id: None,
                origin,
                subject: "core".into(),
                target: Some(Target {
                    document: base_document,
                    switch_to: None,
                }),
            },
            None,
        )
    }

    /// Undo (CHG-04): the newest committed change reverts to its base; an
    /// older one only when no newer change touched the same paths, otherwise
    /// "undo the newer change first".
    pub fn undo(
        &mut self,
        change_id: &str,
        subject: &str,
        idempotency_key: Option<String>,
        request_operation_id: Option<String>,
    ) -> Result<ChangeRecord, CoreError> {
        if let Some(key) = &idempotency_key {
            if let Some(existing) = changes::by_idempotency_key(self.store.connection(), key)? {
                return Ok(existing.record);
            }
        }
        let stored = changes::get(self.store.connection(), change_id)?;
        if stored.record.state != ChangeState::Committed {
            return Err(CoreError::conflict(
                ConflictReason::AlreadyTerminal,
                "only a committed change can be undone",
            ));
        }
        let origin = ChangeOrigin::Undo {
            undoes: change_id.into(),
        };
        if let [ChangeOp::SwitchProfile { to_profile, .. }] = stored.record.ops.as_slice() {
            let (active, current, _) = self.active_head()?;
            let source = profiles::get(self.store.connection(), &stored.record.profile_id)?;
            // A switch never edits either document. Undo it by switching back,
            // only while both ends still have the revisions we switched between.
            if active.profile_id != *to_profile
                || stored.record.committed_revision.as_deref() != Some(&current.revision_id)
                || source.head_revision != stored.record.base_revision
            {
                return Err(CoreError::conflict(
                    ConflictReason::UndoBlockedByNewerChange,
                    "the active composition or either revision changed; undo the newer change first",
                ));
            }
            return self.propose(
                Proposal {
                    profile_id: Some(active.profile_id),
                    base_revision: current.revision_id,
                    ops: vec![ChangeOp::SwitchProfile {
                        to_profile: source.profile_id,
                        to_revision: Some(stored.record.base_revision.clone()),
                    }],
                    mode: ChangeMode::Apply,
                    idempotency_key,
                    request_operation_id,
                    origin,
                    subject: subject.into(),
                    target: None,
                },
                None,
            );
        }
        let latest = changes::latest_committed(self.store.connection(), &stored.record.profile_id)?;
        let (_, head, head_document) =
            profiles::head_document(self.store.connection(), &stored.record.profile_id)?;
        if latest.as_ref().map(|latest| &latest.record.change_id) == Some(&stored.record.change_id)
        {
            let (_, base_document) =
                profiles::revision(self.store.connection(), &stored.record.base_revision)?;
            return self.propose(
                Proposal {
                    profile_id: Some(stored.record.profile_id.clone()),
                    base_revision: head.revision_id,
                    ops: docops::ops_between(&head_document, &base_document),
                    mode: ChangeMode::Apply,
                    idempotency_key,
                    request_operation_id,
                    origin,
                    subject: subject.into(),
                    target: Some(Target {
                        document: base_document,
                        switch_to: None,
                    }),
                },
                None,
            );
        }
        let touched: Vec<String> = stored
            .record
            .card
            .items
            .iter()
            .map(|item| item.path.clone())
            .collect();
        let newer = changes::committed_after(
            self.store.connection(),
            &stored.record.profile_id,
            change_id,
        )?;
        let overlaps = newer.iter().any(|later| {
            later.record.card.items.iter().any(|item| {
                touched.iter().any(|path| {
                    path == &item.path
                        || path.starts_with(&format!("{}/", item.path))
                        || item.path.starts_with(&format!("{path}/"))
                })
            })
        });
        if overlaps {
            return Err(CoreError::conflict(
                ConflictReason::UndoBlockedByNewerChange,
                "a newer change touched the same settings; undo it first",
            ));
        }
        let (_, before) =
            profiles::revision(self.store.connection(), &stored.record.base_revision)?;
        let after = stored
            .target_document
            .clone()
            .ok_or_else(|| CoreError::internal("the change has no recorded target"))?;
        let inverse = docops::ops_between(&after, &before);
        self.propose(
            Proposal {
                profile_id: Some(stored.record.profile_id.clone()),
                base_revision: head.revision_id,
                ops: inverse,
                mode: ChangeMode::Apply,
                idempotency_key,
                request_operation_id,
                origin,
                subject: subject.into(),
                target: None,
            },
            None,
        )
    }

    /// Observation period over: without instability the revision becomes the
    /// protected last-known-good; otherwise it is marked unstable.
    fn observation_end(&mut self, revision_id: &str, _change: &str) {
        let Ok((summary, _)) = profiles::revision(self.store.connection(), revision_id) else {
            return;
        };
        let period = self.core.config.observation_period;
        let since = Instant::now()
            .checked_sub(period)
            .unwrap_or_else(Instant::now);
        if let Some(what) = self.core.unstable_since(since) {
            let _ = self
                .store
                .write(|tx| profiles::mark_unstable(tx, revision_id));
            self.audit(
                summary.origin_change(),
                "core",
                "revision.unstable",
                "marked",
                &what,
            );
            return;
        }
        if summary.pending_confirmation {
            return;
        }
        let _ = self
            .store
            .write(|tx| profiles::set_last_known_good(tx, &summary.profile_id, revision_id));
        self.audit(
            summary.origin_change(),
            "core",
            "revision.last_known_good",
            "set",
            revision_id,
        );
    }

    // ---- supervision and rescue -------------------------------------------------

    /// Disable an entry after repeated failures (REC-02). A ChangeSet like any
    /// other, from origin `supervisor`, allowed while the session is locked.
    pub fn supervisor_disable(&mut self, entry_id: &str, reason: &str) {
        let Ok((_, head, document)) = self.active_head() else {
            return;
        };
        if document.entry(entry_id).is_none_or(|entry| entry.disabled) {
            return;
        }
        let outcome = self.propose(
            Proposal {
                profile_id: None,
                base_revision: head.revision_id,
                ops: vec![ChangeOp::SetEntryDisabled {
                    entry_id: entry_id.into(),
                    disabled: true,
                }],
                mode: ChangeMode::Apply,
                idempotency_key: None,
                request_operation_id: None,
                origin: ChangeOrigin::Supervisor {
                    reason: reason.into(),
                },
                subject: "core".into(),
                target: None,
            },
            None,
        );
        let decision = outcome
            .as_ref()
            .map(|record| record.state.as_str())
            .unwrap_or("failed");
        self.audit(
            None,
            "core",
            "supervisor.disable",
            decision,
            &format!("{entry_id} {reason}"),
        );
    }

    pub fn rescue_disable(
        &mut self,
        target: &str,
        subject: &str,
        idempotency_key: Option<String>,
    ) -> Result<ChangeRecord, CoreError> {
        let (_, head, document) = self.active_head()?;
        let ops: Vec<ChangeOp> = document
            .entries
            .iter()
            .filter(|entry| {
                (entry.entry_id == target || entry.package == target) && !entry.disabled
            })
            .map(|entry| ChangeOp::SetEntryDisabled {
                entry_id: entry.entry_id.clone(),
                disabled: true,
            })
            .collect();
        if ops.is_empty() {
            return Err(CoreError::not_found(format!(
                "no enabled entry or package {target}"
            )));
        }
        self.propose(
            Proposal {
                profile_id: None,
                base_revision: head.revision_id,
                ops,
                mode: ChangeMode::Apply,
                idempotency_key,
                request_operation_id: None,
                origin: ChangeOrigin::Rescue,
                subject: subject.into(),
                target: None,
            },
            None,
        )
    }

    /// Move the head to the last-known-good content. In rescue mode only the
    /// Shell and compositor parts apply now; the Cordis part is recorded as
    /// scheduled for normal mode.
    pub fn rescue_restore(
        &mut self,
        profile_id: Option<&str>,
        subject: &str,
        idempotency_key: Option<String>,
    ) -> Result<ChangeRecord, CoreError> {
        let profile_id = ditto_store::rescue::resolve_profile(self.store.connection(), profile_id)?;
        let (_, head, head_document) =
            profiles::head_document(self.store.connection(), &profile_id)?;
        let (_, good) =
            ditto_store::rescue::last_good_document(self.store.connection(), &profile_id)?;
        self.propose(
            Proposal {
                profile_id: Some(profile_id),
                base_revision: head.revision_id,
                ops: docops::ops_between(&head_document, &good),
                mode: ChangeMode::Apply,
                idempotency_key,
                request_operation_id: None,
                origin: ChangeOrigin::Rescue,
                subject: subject.into(),
                target: Some(Target {
                    document: good,
                    switch_to: None,
                }),
            },
            None,
        )
    }

    /// After a file grant held by a hostd entry is revoked: tell hostd now,
    /// and 5 s later push the projection without the grant.
    pub fn after_revoke(&mut self, grant: &Grant) {
        if let Some(entry_id) = grant.subject.strip_prefix("host:") {
            if let Some(peer) = self.core.hosts.peer() {
                peer.notify(
                    ditto_protocol::host::PERMISSION_REVOKED,
                    json!({"entry_id": entry_id, "grant_id": grant.grant_id, "scope": grant.scope}),
                );
            }
            self.schedule(
                Duration::from_secs(5),
                TimerKind::HostResync,
                entry_id,
                &grant.grant_id,
            );
        }
    }

    pub fn store(&mut self) -> &mut Store {
        &mut self.store
    }

    pub fn store_ref(&self) -> &Store {
        &self.store
    }

    // ---- recovery ---------------------------------------------------------------

    /// Boot recovery (plan/03/02 §13): no change is left between states.
    /// Nothing with side effects is retried; what cannot be decided from a
    /// readback is `unknown`.
    fn recover(&mut self) {
        let in_flight = match changes::in_flight(self.store.connection()) {
            Ok(changes) => changes,
            Err(error) => {
                crate::log::event("recovery.read_failed", &[("reason", &error.to_string())]);
                return;
            }
        };
        for stored in in_flight {
            let change_id = stored.record.change_id.clone();
            let outcome = self.recover_one(&stored);
            let _ = self
                .store
                .write(|tx| changes::set_recovered(tx, &change_id));
            self.audit(
                Some(&change_id),
                "core",
                "recovery",
                &outcome,
                stored.record.state.as_str(),
            );
            crate::log::event(
                "recovery.decided",
                &[("change_id", &change_id), ("outcome", &outcome)],
            );
        }
    }

    fn recover_one(&mut self, stored: &StoredChange) -> String {
        let change_id = stored.record.change_id.as_str();
        match stored.record.state {
            ChangeState::Draft => {
                let _ = self.store.write(|tx| {
                    changes::set_failure(tx, change_id, "recovery.interrupted")?;
                    changes::transition(tx, change_id, ChangeState::Draft, ChangeState::Rejected)
                });
                "rejected".into()
            }
            // No side effect happened before `applying` that recovery cannot
            // simply drop: candidates die with their process.
            ChangeState::Validated | ChangeState::Prepared => {
                let _ = self.store.write(|tx| {
                    changes::set_failure(tx, change_id, "recovery.interrupted")?;
                    changes::transition(tx, change_id, stored.record.state, ChangeState::Aborted)
                });
                "aborted".into()
            }
            ChangeState::Applying | ChangeState::Verifying | ChangeState::RollingBack => {
                self.recover_by_readback(stored)
            }
            _ => "terminal".into(),
        }
    }

    fn recover_by_readback(&mut self, stored: &StoredChange) -> String {
        let change_id = stored.record.change_id.as_str();
        let Some(target) = stored.target_document.clone() else {
            return self.mark_unknown(stored, "recovery.no_target");
        };
        let Ok((_, base)) =
            profiles::revision(self.store.connection(), &stored.record.base_revision)
        else {
            return self.mark_unknown(stored, "recovery.no_base");
        };
        let head_moved = profiles::get(self.store.connection(), &stored.record.profile_id)
            .map(|profile| profile.head_revision != stored.record.base_revision)
            .unwrap_or(true);
        if head_moved {
            // Something else committed on this profile since: this change
            // cannot be finished on its base, and guessing would fork history.
            return self.mark_unknown(stored, "recovery.head_moved");
        }
        let (packages, grants) = self.resolver_parts();
        let paths = self.store.paths().clone();
        let resolver = Resolver {
            packages: &packages,
            paths: &paths,
            grants: &grants,
        };
        let roles = projection::touched(&base, &target, &resolver);
        let mut at_target = true;
        let mut at_base = true;
        let mut items = Vec::new();
        for role in &roles {
            let available = match role {
                ParticipantRole::Shell => self
                    .core
                    .shell
                    .wait_connected(self.core.config.recovery_wait_shell),
                ParticipantRole::Hostd => {
                    if self.core.hosts.is_rescue() {
                        false
                    } else {
                        self.core.hosts.ensure_started();
                        self.core
                            .hosts
                            .wait_ready(self.core.config.recovery_wait_host)
                    }
                }
                ParticipantRole::Compositor => true,
            };
            let participant = if available {
                self.participant(*role).ok()
            } else {
                None
            };
            let Some(participant) = participant else {
                items.push(outcome(
                    0,
                    *role,
                    role_name(*role),
                    OutcomeStatus::Failed,
                    Some("participant_unavailable"),
                ));
                return self.mark_unknown_with(stored, "recovery.participant_unavailable", items);
            };
            if *role == ParticipantRole::Hostd {
                // A restarted hostd holds nothing yet; bring it to the head
                // it will run, which is the base: the change never committed.
                if let Projection::Hostd(host) = projection::projection(*role, &base, &resolver) {
                    self.core.hosts.assign_all(&host);
                }
            }
            let state = participant.state(Some(change_id), STATE_TIMEOUT);
            let Ok(state) = state else {
                return self.mark_unknown_with(stored, "recovery.state_failed", items);
            };
            if state
                .change
                .as_ref()
                .is_some_and(|phase| phase.phase == ParticipantPhase::Committed)
            {
                crate::log::event(
                    "recovery.participant_remembers",
                    &[("change_id", change_id), ("role", role_name(*role))],
                );
            }
            let target_projection = projection::projection(*role, &target, &resolver);
            let base_projection = projection::projection(*role, &base, &resolver);
            let on_target = self
                .judge(&state.observed, &target_projection)
                .iter()
                .all(|verdict| verdict.ok);
            let on_base = self
                .judge(&state.observed, &base_projection)
                .iter()
                .all(|verdict| verdict.ok);
            at_target &= on_target;
            at_base &= on_base;
            items.push(outcome(
                0,
                *role,
                role_name(*role),
                if on_target {
                    OutcomeStatus::Applied
                } else if on_base {
                    OutcomeStatus::Restored
                } else {
                    OutcomeStatus::NotRestored
                },
                None,
            ));
        }
        let state = stored.record.state;
        if at_target && state != ChangeState::RollingBack {
            // Everything reads back as the target: finish the commit.
            let validation = Validation {
                target: target.clone(),
                ops: stored.record.ops.clone(),
                reasons: vec![],
                card: stored.record.card.clone(),
                level: stored.record.hot_swap_level,
                touched: roles.clone(),
            };
            if state == ChangeState::Applying {
                let _ = self.store.write(|tx| {
                    changes::transition(
                        tx,
                        change_id,
                        ChangeState::Applying,
                        ChangeState::Verifying,
                    )
                });
            }
            let switch_to = stored.target_profile.as_ref().and_then(|profile| {
                profiles::get(self.store.connection(), profile)
                    .ok()
                    .map(|summary| (profile.clone(), summary.head_revision))
            });
            return match self.commit_revision(change_id, &validation, stored.mode, switch_to, items)
            {
                Ok(record) => record.state.as_str().into(),
                Err(error) => self.mark_unknown(stored, &error.message),
            };
        }
        let rolling = if state == ChangeState::RollingBack {
            Ok(())
        } else {
            self.store
                .write(|tx| changes::transition(tx, change_id, state, ChangeState::RollingBack))
        };
        if rolling.is_err() {
            return self.mark_unknown(stored, "recovery.transition_failed");
        }
        let terminal = if at_base {
            ChangeState::RolledBack
        } else {
            ChangeState::PartiallyApplied
        };
        let _ = self.store.write(|tx| {
            changes::set_items(tx, change_id, &items)?;
            changes::set_failure(tx, change_id, "recovery.interrupted")?;
            changes::transition(tx, change_id, ChangeState::RollingBack, terminal)
        });
        terminal.as_str().into()
    }

    fn mark_unknown(&mut self, stored: &StoredChange, key: &str) -> String {
        self.mark_unknown_with(stored, key, vec![])
    }

    fn mark_unknown_with(
        &mut self,
        stored: &StoredChange,
        key: &str,
        items: Vec<OutcomeItem>,
    ) -> String {
        let change_id = stored.record.change_id.as_str();
        let state = stored.record.state;
        let _ = self.store.write(|tx| {
            changes::set_items(tx, change_id, &items)?;
            changes::set_failure(tx, change_id, key)?;
            changes::transition(tx, change_id, state, ChangeState::Unknown)
        });
        "unknown".into()
    }
}

fn outcome(
    op_index: u32,
    role: ParticipantRole,
    key: &str,
    status: OutcomeStatus,
    reason: Option<&str>,
) -> OutcomeItem {
    OutcomeItem {
        op_index,
        participant: role_name(role).into(),
        key: key.into(),
        status,
        reason: reason.map(Into::into),
    }
}

/// Changes that need a timed revert (CHG-09): primary shortcuts, turning
/// reduced transparency off. Output scale and keyboard layout join when they
/// become Profile settings.
fn requires_timed_revert(ops: &[ChangeOp], record: &ChangeRecord) -> bool {
    if matches!(
        record.origin,
        ChangeOrigin::TimedRevert { .. }
            | ChangeOrigin::Undo { .. }
            | ChangeOrigin::Rescue
            | ChangeOrigin::Supervisor { .. }
    ) {
        return false;
    }
    ops.iter().any(|op| match op {
        ChangeOp::SetValue { path, after, .. } => {
            path.starts_with("/shortcuts")
                || (path == "/appearance/reduced_transparency" && after == &json!(false))
                || (path == "/appearance" && after.get("reduced_transparency") == Some(&json!(false))
                    && matches!(op, ChangeOp::SetValue { before: Some(before), .. } if before.get("reduced_transparency") == Some(&json!(true))))
        }
        _ => false,
    })
}

fn copy_tree(source: &Path, target: &Path) -> std::io::Result<()> {
    std::fs::create_dir_all(target)?;
    for entry in std::fs::read_dir(source)? {
        let entry = entry?;
        let destination = target.join(entry.file_name());
        if entry.file_type()?.is_dir() {
            copy_tree(&entry.path(), &destination)?;
        } else if entry.file_type()?.is_file() {
            std::fs::copy(entry.path(), destination)?;
        }
    }
    Ok(())
}

/// The compositor participant lives in Core; this handle lets the executor
/// treat it like the remote ones.
struct CompositorHandle(Arc<Core>);

impl Participant for CompositorHandle {
    fn role(&self) -> ParticipantRole {
        ParticipantRole::Compositor
    }
    fn prepare(
        &self,
        params: &PrepareParams,
        timeout: Duration,
    ) -> crate::participants::ParticipantResult<ditto_protocol::participant::StepReport> {
        self.0.compositor.prepare(params, timeout)
    }
    fn commit(
        &self,
        change_id: &str,
        timeout: Duration,
    ) -> crate::participants::ParticipantResult<ditto_protocol::participant::StepReport> {
        self.0.compositor.commit(change_id, timeout)
    }
    fn abort(
        &self,
        change_id: &str,
        timeout: Duration,
    ) -> crate::participants::ParticipantResult<()> {
        self.0.compositor.abort(change_id, timeout)
    }
    fn rollback(
        &self,
        change_id: &str,
        timeout: Duration,
    ) -> crate::participants::ParticipantResult<ditto_protocol::participant::StepReport> {
        self.0.compositor.rollback(change_id, timeout)
    }
    fn state(
        &self,
        change_id: Option<&str>,
        timeout: Duration,
    ) -> crate::participants::ParticipantResult<ditto_protocol::participant::StateOutput> {
        self.0.compositor.state(change_id, timeout)
    }
}

trait OriginChange {
    fn origin_change(&self) -> Option<&str>;
}

impl OriginChange for ditto_protocol::profile::RevisionSummary {
    fn origin_change(&self) -> Option<&str> {
        match &self.origin {
            RevisionOrigin::Change { change_id } => Some(change_id),
            _ => None,
        }
    }
}

pub fn catalog_hostd_slot(capability_id: &str) -> Option<&'static str> {
    catalog::contract(capability_id).and_then(|contract| match contract.provider {
        catalog::Provider::Hostd(slot) => Some(slot),
        _ => None,
    })
}

pub fn unavailable_reason_for_rescue() -> UnavailableReason {
    UnavailableReason::RescueMode
}
