//! An inspection-only declarative SDK. This is not GeneratedArtifact, a wire
//! contract, package installer, permission authority, or activation path.
//! Formal Core-owned records will be added after the G2 measurement gate.
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::BTreeSet;

pub const MAX_DESCRIPTION_BYTES: usize = 16 * 1024;
const TASK_SOURCE: &str = include_str!("../templates/TasksSummary.qml");
const WORKSPACE_SOURCE: &str = include_str!("../templates/WorkspaceActions.qml");

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Description {
    pub format_version: u32,
    pub plugin_id: String,
    pub version: String,
    pub title: String,
    pub width: u16,
    pub accent: String,
    pub content: Content,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "template", rename_all = "snake_case", deny_unknown_fields)]
pub enum Content {
    TasksSummaryV1 {
        max_items: u8,
        show_completed: bool,
        order: TaskOrder,
    },
    WorkspaceActionsV1 {
        actions: Vec<WorkspaceAction>,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TaskOrder {
    Source,
    Title,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
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
        serde_json::from_str(include_str!("../examples/tasks-summary.json")).unwrap()
    }

    #[test]
    fn both_templates_produce_inspection_candidates_only() {
        for bytes in [
            include_bytes!("../examples/tasks-summary.json").as_slice(),
            include_bytes!("../examples/workspace-actions.json").as_slice(),
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
        let b = Description::parse(include_bytes!("../examples/tasks-summary.json")).unwrap();
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
        let mut workspace: serde_json::Value =
            serde_json::from_str(include_str!("../examples/workspace-actions.json")).unwrap();
        workspace["content"]["actions"][1]["workspace_id"] =
            workspace["content"]["actions"][0]["workspace_id"].clone();
        assert!(Description::parse(&serde_json::to_vec(&workspace).unwrap()).is_err());
        assert!(Description::parse(&vec![b' '; MAX_DESCRIPTION_BYTES + 1]).is_err());
    }
}
