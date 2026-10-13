//! Rust-first restricted generation contracts and deterministic description validation.
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::collections::BTreeSet;

pub const MAX_DESCRIPTION_BYTES: usize = 16 * 1024;
const TASK_SOURCE: &str = include_str!("../../ditto-generation/templates/TasksSummary.qml");
const WORKSPACE_SOURCE: &str =
    include_str!("../../ditto-generation/templates/WorkspaceActions.qml");

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Description {
    pub format_version: u32,
    pub plugin_id: String,
    pub version: String,
    pub title: String,
    #[schemars(range(min = 160, max = 640))]
    pub width: u16,
    pub accent: String,
    pub content: Content,
    #[serde(default)]
    pub data: DataPlan,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(tag = "template", rename_all = "snake_case", deny_unknown_fields)]
pub enum Content {
    TasksSummaryV1 {
        #[schemars(range(min = 1, max = 20))]
        max_items: u8,
        show_completed: bool,
        order: TaskOrder,
    },
    WorkspaceActionsV1 {
        #[schemars(length(min = 1, max = 16))]
        actions: Vec<WorkspaceAction>,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum TaskOrder {
    Source,
    Title,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct WorkspaceAction {
    pub workspace_id: String,
    pub label: String,
}

#[derive(Debug, Serialize)]
pub struct Inspection {
    pub format_version: u32,
    pub disposition: &'static str,
    pub description: Description,
    pub description_sha256: String,
    pub template_sha256: String,
    pub template_source: &'static str,
    pub required_capabilities: Vec<&'static str>,
    pub validation: &'static str,
    pub activation_available: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum DataType {
    Text,
    Integer,
    Boolean,
    TextList,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema, Default)]
#[serde(rename_all = "snake_case")]
pub enum RollbackPolicy {
    #[default]
    Snapshot,
    Compatible,
    Unavailable,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct DataMigration {
    pub from_version: u32,
    #[serde(default)]
    pub rename: BTreeMap<String, String>,
    #[serde(default)]
    pub defaults: BTreeMap<String, Value>,
    #[serde(default)]
    pub remove: Vec<String>,
    pub rollback: RollbackPolicy,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct DataPlan {
    pub schema_version: u32,
    #[serde(default)]
    pub fields: BTreeMap<String, DataType>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub migration: Option<DataMigration>,
}
impl Default for DataPlan {
    fn default() -> Self {
        Self {
            schema_version: 1,
            fields: BTreeMap::new(),
            migration: None,
        }
    }
}
impl DataPlan {
    pub fn validate(&self) -> Result<(), String> {
        let key = |s: &str| {
            !s.is_empty()
                && s.len() <= 64
                && s.bytes()
                    .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == b'_')
        };
        if self.schema_version == 0 || self.fields.len() > 32 || self.fields.keys().any(|s| !key(s))
        {
            return Err("invalid_data_schema".into());
        }
        if let Some(m) = &self.migration {
            if m.from_version == 0
                || m.from_version >= self.schema_version
                || m.rename.len() > 32
                || m.remove.len() > 32
                || m.defaults.len() > 32
                || m.rename
                    .iter()
                    .any(|(a, b)| !key(a) || !key(b) || !self.fields.contains_key(b))
                || m.remove.iter().any(|k| !key(k))
                || m.defaults.iter().any(|(k, v)| !self.accepts(k, v))
            {
                return Err("invalid_data_migration".into());
            }
            let destinations: BTreeSet<_> = m.rename.values().collect();
            if destinations.len() != m.rename.len() {
                return Err("duplicate_migration_destination".into());
            }
            if m.rollback == RollbackPolicy::Compatible
                && (!m.rename.is_empty() || !m.remove.is_empty())
            {
                return Err("destructive_migration_not_compatible".into());
            }
        }
        Ok(())
    }
    pub fn accepts(&self, key: &str, value: &Value) -> bool {
        match self.fields.get(key) {
            Some(DataType::Text) => value.as_str().is_some_and(|s| s.len() <= 8192),
            Some(DataType::Integer) => value
                .as_i64()
                .is_some_and(|n| (-9_007_199_254_740_991..=9_007_199_254_740_991).contains(&n)),
            Some(DataType::Boolean) => value.is_boolean(),
            Some(DataType::TextList) => value.as_array().is_some_and(|a| {
                a.len() <= 128
                    && a.iter()
                        .all(|v| v.as_str().is_some_and(|s| s.len() <= 1024))
            }),
            None => false,
        }
    }
    pub fn validate_payload(&self, value: &Value) -> Result<(), String> {
        let object = value.as_object().ok_or("data_must_be_an_object")?;
        if serde_json::to_vec(value).map_err(|e| e.to_string())?.len() > 64 * 1024
            || object.iter().any(|(k, v)| !self.accepts(k, v))
        {
            return Err("data_does_not_match_schema".into());
        }
        Ok(())
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum Enforcement {
    Full,
    Partial,
    Unavailable,
}
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct GenerationBoundary {
    pub enforcement: Enforcement,
    pub policy: String,
    pub landlock_abi: i64,
    pub files: bool,
    pub network: bool,
    pub process_exec_blocked: bool,
    pub memory_max: u64,
    pub cpu_max: String,
    pub pids_max: u32,
    pub deadline_ms: u64,
    pub cleanup_complete: bool,
    pub reasons: Vec<String>,
    pub unit: Option<String>,
    pub cgroup: Option<String>,
    pub runner_pid: Option<u32>,
}
impl GenerationBoundary {
    pub fn full(&self) -> bool {
        self.enforcement == Enforcement::Full
            && self.policy == "generated-templates-v1"
            && self.landlock_abi >= 6
            && self.files
            && self.network
            && self.process_exec_blocked
            && self.cleanup_complete
            && self.memory_max == 512 * 1024 * 1024
            && self.pids_max == 64
            && self.cpu_max == "100000 100000"
            && self.runner_pid.is_some_and(|p| p > 0)
            && self.unit.as_ref().is_some_and(|unit| {
                unit.starts_with("ditto-generation-")
                    && unit.ends_with(".service")
                    && self
                        .cgroup
                        .as_ref()
                        .is_some_and(|c| c.ends_with(&format!("/{unit}")))
            })
            && self.deadline_ms > 0
            && self.deadline_ms <= 120_000
    }
}
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum ValidationStage {
    Syntax,
    Contract,
    Load,
    Focus,
    Interaction,
}
pub const VALIDATION_STAGES: [ValidationStage; 5] = [
    ValidationStage::Syntax,
    ValidationStage::Contract,
    ValidationStage::Load,
    ValidationStage::Focus,
    ValidationStage::Interaction,
];
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum StageResult {
    Passed,
    Failed,
    NotRun,
}
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct StageEvidence {
    pub stage: ValidationStage,
    pub result: StageResult,
    pub diagnostic: String,
}
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct GenerationValidation {
    pub bundle_sha256: String,
    pub boundary: GenerationBoundary,
    pub stages: Vec<StageEvidence>,
    pub test_data: bool,
    pub preview_opened: bool,
    #[serde(default)]
    pub diagnostics: Vec<String>,
}
impl GenerationValidation {
    pub fn passed(&self, hash: &str) -> bool {
        self.bundle_sha256 == hash
            && self.boundary.full()
            && self.stages.len() == 5
            && self
                .stages
                .iter()
                .zip(VALIDATION_STAGES)
                .all(|(e, s)| e.stage == s && e.result == StageResult::Passed)
            && self.test_data
    }
}
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct GenerationOrigin {
    pub request_summary: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub turn_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum ArtifactState {
    Candidate,
    Validating,
    InspectOnly,
    Validated,
    Published,
    Active,
    Failed,
}
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema, Default)]
#[serde(deny_unknown_fields)]
pub struct RepairBudget {
    pub attempts: u32,
    pub stopped: bool,
    pub failure_fingerprints: Vec<String>,
}
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ActivationRecord {
    pub change_id: String,
    pub state: String,
    pub revision: Option<String>,
    pub at: String,
}
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct GeneratedArtifact {
    pub artifact_id: String,
    pub description: Description,
    pub manifest: crate::manifest::Manifest,
    pub dependencies: BTreeMap<String, String>,
    pub source_files: BTreeMap<String, String>,
    pub config_schema: Value,
    pub origin: GenerationOrigin,
    pub parent_id: Option<String>,
    pub bundle_sha256: String,
    pub created_at: String,
    pub state: ArtifactState,
    pub validation: Option<GenerationValidation>,
    pub validation_job_id: Option<String>,
    pub repair: RepairBudget,
    pub activations: Vec<ActivationRecord>,
    pub changed_fields: Vec<String>,
    #[serde(default)]
    pub previews: Vec<PreviewRecord>,
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct PreviewRecord {
    pub job_id: String,
    pub state: String,
    pub opened: bool,
    pub at: String,
}
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct GenerateInput {
    pub description: Description,
    pub request_summary: String,
    #[serde(default)]
    pub parent_id: Option<String>,
    pub idempotency_key: String,
}
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ArtifactInput {
    pub artifact_id: String,
}
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct GenerationJobInput {
    pub artifact_id: String,
    pub idempotency_key: String,
}
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct GenerationActivateInput {
    pub artifact_id: String,
    pub base_revision: String,
    pub idempotency_key: String,
    #[serde(default)]
    pub entry_id: Option<String>,
}
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ArtifactsOutput {
    pub artifacts: Vec<GeneratedArtifact>,
}
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct GeneratedDataInput {
    pub artifact_id: String,
    pub payload: Value,
    pub expected_revision: u64,
}
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct GeneratedData {
    pub plugin_id: String,
    pub schema_version: u32,
    pub revision: u64,
    pub payload: Value,
}

/// The complete immutable source bundle. Validation and activation records
/// live beside it in Core, so retries never change the content being tested.
pub type SourceBundle = (
    crate::manifest::Manifest,
    BTreeMap<String, String>,
    BTreeMap<String, String>,
    String,
);
pub fn bundle(description: &Description) -> Result<SourceBundle, String> {
    description.validate()?;
    let inspection = description.inspect()?;
    let config_schema =
        serde_json::json!({"type":"object","properties":{},"additionalProperties":false});
    let fields:serde_json::Map<String,Value>=description.data.fields.iter().map(|(name,kind)| {
        let schema=match kind {
            DataType::Text=>serde_json::json!({"type":"string","maxLength":8192}),
            DataType::Integer=>serde_json::json!({"type":"integer","minimum":-9_007_199_254_740_991_i64,"maximum":9_007_199_254_740_991_i64}),
            DataType::Boolean=>serde_json::json!({"type":"boolean"}),
            DataType::TextList=>serde_json::json!({"type":"array","maxItems":128,"items":{"type":"string","maxLength":1024}}),
        };
        (name.clone(),schema)
    }).collect();
    let data_schema =
        serde_json::json!({"type":"object","properties":fields,"additionalProperties":false});
    let manifest: crate::manifest::Manifest = serde_json::from_value(serde_json::json!({
        "manifest_version":1,"id":description.plugin_id,"version":description.version,
        "name":{"zh-TW":description.title,"en":description.title},"author":"Ditto user","license":"UNLICENSED",
        "source":"generated","plugin_kind":"qml_provider","host_kind":"qml","trust_level":"untrusted",
        "runtime":{"qt":"=6.10.2"},"platform":["linux-x86_64"],"required_protocol_version":"^0.3",
        "slots":["ui.generated_panel"],"qml_entry":"qml/Panel.qml","config_schema":config_schema,
        "data_schema":data_schema,"hot_swap":"instant","health":{"timeout_ms":2000},"cleanup":{"timeout_ms":5000},
        "idle_policy":"resident","resource_budget":{"memory_mib":12,"cpu_percent":2},"rescue":{"disable_safe":true}
    })).map_err(|e| e.to_string())?;
    let dependencies = BTreeMap::from([
        ("qt".into(), "6.10.2".into()),
        ("protocol".into(), crate::PROTOCOL_VERSION.into()),
        ("template_sha256".into(), inspection.template_sha256.clone()),
    ]);
    let encode = |v: &Value| -> Result<String, String> { Ok(crate::jcs::canonicalize(v)) };
    let files = BTreeMap::from([
        ("qml/Panel.qml".into(), inspection.template_source.into()),
        (
            "description.json".into(),
            encode(&serde_json::to_value(description).map_err(|e| e.to_string())?)?,
        ),
        (
            "manifest.json".into(),
            encode(&serde_json::to_value(&manifest).map_err(|e| e.to_string())?)?,
        ),
        (
            "dependencies.lock.json".into(),
            encode(&serde_json::to_value(&dependencies).map_err(|e| e.to_string())?)?,
        ),
        ("config.schema.json".into(), encode(&config_schema)?),
        (
            "data.schema.json".into(),
            encode(&serde_json::to_value(&description.data).map_err(|e| e.to_string())?)?,
        ),
    ]);
    let hash = crate::jcs::digest(&serde_json::to_value(&files).map_err(|e| e.to_string())?);
    Ok((manifest, files, dependencies, hash))
}

fn text(value: &str, max: usize) -> bool {
    !value.trim().is_empty() && value.chars().count() <= max && !value.chars().any(char::is_control)
}

impl Description {
    pub fn parse(bytes: &[u8]) -> Result<Self, String> {
        if bytes.len() > MAX_DESCRIPTION_BYTES {
            return Err("description_too_large".into());
        }
        let description: Self =
            serde_json::from_slice(bytes).map_err(|e| format!("description_invalid: {e}"))?;
        description.validate()?;
        Ok(description)
    }

    pub fn validate(&self) -> Result<(), String> {
        if serde_json::to_vec(self).map_err(|e| e.to_string())?.len() > MAX_DESCRIPTION_BYTES {
            return Err("description_too_large".into());
        }
        if self.format_version != 1 {
            return Err("unsupported_description_version".into());
        }
        if !self.plugin_id.starts_with("local.generated.")
            || self.plugin_id.len() > 128
            || self.plugin_id.split('.').any(|part| {
                part.is_empty()
                    || !part
                        .bytes()
                        .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == b'_')
            })
        {
            return Err("invalid_generated_plugin_id".into());
        }
        let version: Vec<&str> = self.version.split('.').collect();
        if version.len() != 3
            || version.iter().any(|v| {
                v.is_empty()
                    || (v.len() > 1 && v.starts_with('0'))
                    || !v.bytes().all(|c| c.is_ascii_digit())
                    || v.parse::<u32>().is_err()
            })
        {
            return Err("version_must_be_numeric_semver".into());
        }
        if !text(&self.title, 80) {
            return Err("invalid_panel_title".into());
        }
        if !(160..=640).contains(&self.width) {
            return Err("panel_width_out_of_bounds".into());
        }
        if self.accent.len() != 7
            || !self.accent.starts_with('#')
            || !self.accent.as_bytes()[1..]
                .iter()
                .all(u8::is_ascii_hexdigit)
        {
            return Err("invalid_accent_color".into());
        }
        self.data.validate()?;
        match &self.content {
            Content::TasksSummaryV1 { max_items, .. } if !(1..=20).contains(max_items) => {
                return Err("task_count_out_of_bounds".into())
            }
            Content::WorkspaceActionsV1 { actions } => {
                if actions.is_empty() || actions.len() > 16 {
                    return Err("workspace_action_count_out_of_bounds".into());
                }
                let mut ids = BTreeSet::new();
                for action in actions {
                    if !text(&action.workspace_id, 64)
                        || !text(&action.label, 80)
                        || !ids.insert(&action.workspace_id)
                    {
                        return Err("invalid_or_duplicate_workspace_action".into());
                    }
                }
            }
            _ => {}
        }
        Ok(())
    }

    /// Descriptor data never enters QML source interpolation. The fixed,
    /// versioned template reads data properties and uses Text.PlainText.
    pub fn inspect(&self) -> Result<Inspection, String> {
        self.validate()?;
        let (template_source, required_capabilities) = match self.content {
            Content::TasksSummaryV1 { .. } => (TASK_SOURCE, vec!["desktop.tasks.list"]),
            Content::WorkspaceActionsV1 { .. } => (
                WORKSPACE_SOURCE,
                vec!["desktop.workspaces.list", "desktop.workspaces.activate"],
            ),
        };
        let hash = |bytes: &[u8]| format!("{:x}", Sha256::digest(bytes));
        Ok(Inspection {
            format_version: 1,
            disposition: "inspect_only",
            description: self.clone(),
            description_sha256: hash(&serde_json::to_vec(self).map_err(|e| e.to_string())?),
            template_sha256: hash(template_source.as_bytes()),
            template_source,
            required_capabilities,
            validation: "description_only; isolated syntax/load/focus/interaction not run",
            activation_available: false,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn tasks() -> serde_json::Value {
        serde_json::from_str(include_str!(
            "../../ditto-generation/examples/tasks-summary.json"
        ))
        .unwrap()
    }

    #[test]
    fn both_templates_produce_inspection_candidates_only() {
        for bytes in [
            include_bytes!("../../ditto-generation/examples/tasks-summary.json").as_slice(),
            include_bytes!("../../ditto-generation/examples/workspace-actions.json").as_slice(),
        ] {
            let inspection = Description::parse(bytes).unwrap().inspect().unwrap();
            assert_eq!(inspection.disposition, "inspect_only");
            assert!(!inspection.activation_available);
            assert_eq!(inspection.description_sha256.len(), 64);
            assert!(inspection.template_source.contains("Text.PlainText"));
        }
    }

    #[test]
    fn code_imports_paths_urls_and_entrypoints_are_not_fields() {
        for field in [
            "qml",
            "source",
            "imports",
            "entry",
            "qml_entry",
            "url",
            "path",
            "command",
            "permissions",
            "trust_level",
            "enforcement",
        ] {
            let mut input = tasks();
            input[field] = serde_json::json!("arbitrary");
            assert!(
                Description::parse(&serde_json::to_vec(&input).unwrap()).is_err(),
                "{field}"
            );
            let mut nested = tasks();
            nested["content"][field] = serde_json::json!("arbitrary");
            assert!(
                Description::parse(&serde_json::to_vec(&nested).unwrap()).is_err(),
                "content.{field}"
            );
        }
    }

    #[test]
    fn unknown_templates_versions_and_enum_values_are_rejected() {
        for (path, value) in [
            ("/content/template", serde_json::json!("free_qml")),
            ("/content/order", serde_json::json!("evaluate_script")),
            ("/format_version", serde_json::json!(2)),
        ] {
            let mut input = tasks();
            *input.pointer_mut(path).unwrap() = value;
            assert!(Description::parse(&serde_json::to_vec(&input).unwrap()).is_err());
        }
    }

    #[test]
    fn titles_remain_plain_data_and_never_change_template_source() {
        let initial = Description::parse(&serde_json::to_vec(&tasks()).unwrap()).unwrap();
        let mut injected = initial.clone();
        injected.title =
            "\"; Qt.createQmlObject('import Quickshell.Io', parent); // <b>x</b>".into();
        let a = initial.inspect().unwrap();
        let b = injected.inspect().unwrap();
        assert_eq!(a.template_source, b.template_source);
        assert_eq!(a.template_sha256, b.template_sha256);
        assert_ne!(a.description_sha256, b.description_sha256);
        assert!(!b.template_source.contains("Qt.createQmlObject"));
    }

    #[test]
    fn descriptor_key_order_does_not_change_content_hash() {
        let a = Description::parse(&serde_json::to_vec(&tasks()).unwrap()).unwrap();
        let b = Description::parse(include_bytes!(
            "../../ditto-generation/examples/tasks-summary.json"
        ))
        .unwrap();
        assert_eq!(
            a.inspect().unwrap().description_sha256,
            b.inspect().unwrap().description_sha256
        );
    }

    #[test]
    fn invalid_ids_versions_colors_sizes_and_duplicates_are_rejected() {
        for (field, value) in [
            ("plugin_id", serde_json::json!("../escape")),
            ("plugin_id", serde_json::json!("ditto.builtin")),
            ("version", serde_json::json!("01.0.0")),
            ("version", serde_json::json!("+1.0.0")),
            ("accent", serde_json::json!("file:///secret")),
            ("width", serde_json::json!(650)),
            ("title", serde_json::json!("\u{0}")),
        ] {
            let mut input = tasks();
            input[field] = value;
            assert!(
                Description::parse(&serde_json::to_vec(&input).unwrap()).is_err(),
                "{field}"
            );
        }
        let mut workspace: serde_json::Value = serde_json::from_str(include_str!(
            "../../ditto-generation/examples/workspace-actions.json"
        ))
        .unwrap();
        workspace["content"]["actions"][1]["workspace_id"] =
            workspace["content"]["actions"][0]["workspace_id"].clone();
        assert!(Description::parse(&serde_json::to_vec(&workspace).unwrap()).is_err());
        assert!(Description::parse(&vec![b' '; MAX_DESCRIPTION_BYTES + 1]).is_err());
    }
}

#[cfg(test)]
mod attestation_tests {
    use super::*;
    fn report() -> GenerationValidation {
        GenerationValidation {
            bundle_sha256: "sha256:candidate".into(),
            boundary: GenerationBoundary {
                enforcement: Enforcement::Full,
                policy: "generated-templates-v1".into(),
                landlock_abi: 8,
                files: true,
                network: true,
                process_exec_blocked: true,
                memory_max: 536870912,
                cpu_max: "100000 100000".into(),
                pids_max: 64,
                deadline_ms: 15000,
                cleanup_complete: true,
                reasons: vec![],
                unit: Some("ditto-generation-fixture.service".into()),
                cgroup: Some("/fixture/ditto-generation-fixture.service".into()),
                runner_pid: Some(1),
            },
            stages: VALIDATION_STAGES
                .into_iter()
                .map(|stage| StageEvidence {
                    stage,
                    result: StageResult::Passed,
                    diagnostic: "fixture".into(),
                })
                .collect(),
            test_data: true,
            preview_opened: false,
            diagnostics: vec![],
        }
    }
    #[test]
    fn every_failed_or_unexecuted_stage_prevents_approval() {
        let r = report();
        assert!(r.passed(&r.bundle_sha256));
        for stage in 0..5 {
            let mut failure = r.clone();
            failure.stages[stage].result = StageResult::Failed;
            for following in (stage + 1)..5 {
                failure.stages[following].result = StageResult::NotRun;
            }
            assert!(!failure.passed(&r.bundle_sha256));
        }
        let mut wrong = r.clone();
        wrong.stages.swap(0, 1);
        assert!(!wrong.passed(&r.bundle_sha256));
        wrong = r.clone();
        wrong.stages.pop();
        assert!(!wrong.passed(&r.bundle_sha256));
    }
    #[test]
    fn diagnostic_partial_missing_or_mismatched_boundaries_never_approve() {
        let r = report();
        for kind in 0..10 {
            let mut v = r.clone();
            match kind {
                0 => v.boundary.policy = "diagnostic-v1".into(),
                1 => v.boundary.enforcement = Enforcement::Partial,
                2 => v.boundary.enforcement = Enforcement::Unavailable,
                3 => v.boundary.process_exec_blocked = false,
                4 => v.boundary.cleanup_complete = false,
                5 => v.boundary.memory_max = 0,
                6 => v.boundary.landlock_abi = 4,
                7 => v.boundary.cgroup = Some("/different/service".into()),
                8 => v.boundary.runner_pid = None,
                _ => v.bundle_sha256 = "sha256:other".into(),
            };
            assert!(!v.passed(&r.bundle_sha256), "boundary case {kind}");
        }
    }
}
