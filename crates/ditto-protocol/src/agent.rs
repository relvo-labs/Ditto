//! G2 conversation contract. Core owns the log; the Agent owns only a writer
//! lease bound to its authenticated connection. Model providers are execution
//! backends, not configuration or conversation stores.
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use serde_json::Value;

pub const SESSION_FORMAT_VERSION: u32 = 1;
pub const MAX_EVENT_BYTES: usize = 262_144;
pub const MAX_BATCH_EVENTS: usize = 128;
pub const MAX_MESSAGE_BYTES: usize = 65_536;

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct Conversation {
    pub session_id: String,
    pub format_version: u32,
    pub title: String,
    pub created_at: String,
    pub next_seq: u64,
    pub durable_seq: u64,
}

/// Restricted Harness vocabulary (pinned 477b4f4); unknown required events
/// refuse decoding rather than silently reconstructing a different history.
#[derive(Clone, Copy, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
pub enum SessionEventKind {
    #[serde(rename = "user/message")]
    UserMessage,
    #[serde(rename = "assistant/message")]
    AssistantMessage,
    #[serde(rename = "turn/start")]
    TurnStart,
    #[serde(rename = "turn/end")]
    TurnEnd,
    #[serde(rename = "tool/call")]
    ToolCall,
    #[serde(rename = "tool/result")]
    ToolResult,
    #[serde(rename = "approval/asked")]
    ApprovalAsked,
    #[serde(rename = "approval/decided")]
    ApprovalDecided,
    #[serde(rename = "model/selection")]
    ModelSelection,
    #[serde(rename = "compaction/summary")]
    CompactionSummary,
    #[serde(rename = "session/title")]
    SessionTitle,
    #[serde(rename = "request/context")]
    ContextReference,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct SessionEvent {
    pub seq: u64,
    #[serde(rename = "type")]
    pub kind: SessionEventKind,
    pub data: Value,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct SessionCreateInput {
    pub title: String,
    pub idempotency_key: String,
}
#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct SessionIdInput {
    pub session_id: String,
}
#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct SessionsListOutput {
    pub sessions: Vec<Conversation>,
}
#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct SessionReadInput {
    pub session_id: String,
    #[serde(default)]
    pub offset: u64,
    #[serde(default = "page_size")]
    pub limit: u32,
}
fn page_size() -> u32 {
    50
}
#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct SessionReadOutput {
    pub session: Conversation,
    pub events: Vec<SessionEvent>,
}
#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct SessionOpenOutput {
    pub session: Conversation,
    pub writer_lease: String,
}
#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct SessionWriteInput {
    pub session_id: String,
    pub writer_lease: String,
}
#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct SessionAppendInput {
    pub session_id: String,
    pub writer_lease: String,
    pub batch_id: String,
    pub expected_next_seq: u64,
    pub events: Vec<SessionEvent>,
}
#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct SessionDeleteOutput {
    pub deleted: bool,
    pub configuration_preserved: bool,
}
#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct ProfileUpgradeInput {
    pub profile_id: Option<String>,
    pub base_revision: String,
    pub idempotency_key: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum ProviderAuthentication {
    CodexSubscription { connection_ref: String },
    ApiKey { credential_ref: String },
}
#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct AgentPreferences {
    pub revision: u64,
    pub enabled: bool,
    pub provider: String,
    pub model: Option<String>,
    pub reasoning_effort: Option<String>,
    pub auth: Option<ProviderAuthentication>,
    pub max_tool_calls: u32,
    pub turn_timeout_ms: u64,
    pub retain_conversations: bool,
    /// `ask`: an Agent call outside its grants asks the person once.
    /// `never`: nobody is asked; such calls are refused (existing grants
    /// still apply). Never an automatic yes.
    #[serde(default)]
    pub approval_mode: ApprovalMode,
}
#[derive(Clone, Copy, Debug, Default, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ApprovalMode {
    #[default]
    Ask,
    Never,
}
#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct ApprovalsListOutput {
    /// Undecided, unexpired requests the caller may see.
    pub approvals: Vec<Approval>,
}
impl Default for AgentPreferences {
    fn default() -> Self {
        Self {
            revision: 0,
            enabled: false,
            provider: "codex-app-server".into(),
            model: None,
            reasoning_effort: None,
            auth: None,
            max_tool_calls: 24,
            turn_timeout_ms: 120_000,
            retain_conversations: true,
            approval_mode: ApprovalMode::Ask,
        }
    }
}
#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct PreferencesPatchInput {
    pub expected_revision: u64,
    pub settings: AgentPreferences,
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum TurnState {
    Queued,
    Running,
    AwaitingApproval,
    Cancelling,
    Succeeded,
    Failed,
    Partial,
    Unknown,
    Cancelled,
}
impl TurnState {
    pub fn terminal(self) -> bool {
        matches!(
            self,
            Self::Succeeded | Self::Failed | Self::Partial | Self::Unknown | Self::Cancelled
        )
    }
}
#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct TurnSubmitInput {
    pub session_id: String,
    pub client_message_id: String,
    pub text: String,
}
#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct Turn {
    pub turn_id: String,
    pub session_id: String,
    pub state: TurnState,
    pub created_at: String,
    pub settings_revision: u64,
    pub tool_calls: u32,
    pub operation_ids: Vec<String>,
    pub error_reason: Option<String>,
}
#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct TurnIdInput {
    pub turn_id: String,
}
#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct TurnCompleteInput {
    pub turn_id: String,
    pub state: TurnState,
    pub error_reason: Option<String>,
}
#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct TurnClaimOutput {
    pub turn: Turn,
    pub text: String,
    pub message_seq: u64,
    pub settings: AgentPreferences,
    /// The latest ChangeSets this conversation produced, newest first, as
    /// Core recorded them: what "that", "it" or "a bit more" can refer to.
    #[serde(default)]
    pub recent_changes: Vec<RecentChange>,
}

#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct RecentChange {
    pub change_id: String,
    pub turn_id: String,
    pub state: crate::change::ChangeState,
    pub result: Option<crate::change::ResultKind>,
    pub items: Vec<crate::profile::DiffItem>,
}
#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct ToolIntentInput {
    pub turn_id: String,
    pub tool_call_id: String,
    pub capability_id: String,
    pub arguments: Value,
}
#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct ToolIntent {
    pub intent_id: String,
    pub turn_id: String,
    pub tool_call_id: String,
    pub capability_id: String,
    pub payload_hash: String,
    pub previous_result: Option<Value>,
}
#[derive(Clone, Copy, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ToolAbandonReason {
    PermissionDenied,
    Cancelled,
}
#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct ToolAbandonInput {
    pub intent_id: String,
    pub reason: ToolAbandonReason,
}
#[derive(Clone, Copy, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum RuntimePhase {
    Stopped,
    Starting,
    Ready,
    Draining,
    Failed,
}
#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct AgentRuntimeStatus {
    pub installed: bool,
    pub phase: RuntimePhase,
    pub generation: u64,
    pub controller_pid: Option<u32>,
    pub backend_pid: Option<u32>,
    pub active_turns: u32,
    pub isolation_verified: bool,
    pub failure_reason: Option<String>,
}
#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(deny_unknown_fields)]
/// The controller reports readiness only. Backend identity and isolation are
/// known to Core from its own launch and are never taken from this message.
pub struct AgentReadyInput {}
#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct ProviderLoginInput {
    pub provider: String,
}
#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct ProviderCancelLoginInput {
    pub provider: String,
    pub login_id: String,
}
#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct ProviderLoginOutput {
    pub login_id: String,
    pub auth_url: String,
    pub expires_at_ms: u64,
}
#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct ProviderActionOutput {
    pub completed: bool,
}
#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct ProviderStatus {
    pub available: bool,
    pub provider: String,
    pub authenticated: bool,
    pub account_label: Option<String>,
    pub models: Vec<ProviderModel>,
    pub rate_limits: Option<ProviderRateLimits>,
}
#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct ProviderModel {
    pub id: String,
    pub label: String,
    pub reasoning_efforts: Vec<String>,
    pub default_effort: Option<String>,
    pub supports_images: bool,
}
#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct ProviderRateWindow {
    pub used_percent: f64,
    pub resets_at_ms: Option<u64>,
    pub window_minutes: Option<u32>,
}
#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct ProviderRateLimits {
    pub primary: Option<ProviderRateWindow>,
    pub secondary: Option<ProviderRateWindow>,
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
pub enum ApprovalDecision {
    AllowedOnce,
    Rejected,
    Cancelled,
    Unavailable,
}
#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct ApprovalRequestInput {
    pub session_id: String,
    pub turn_id: String,
    pub capability_id: String,
    pub resource: String,
    pub intent_hash: String,
    pub purpose: String,
}
#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct Approval {
    pub request_id: String,
    pub principal: String,
    pub generation: String,
    pub request: ApprovalRequestInput,
    pub expires_at_ms: u64,
    pub decision: Option<ApprovalDecision>,
    pub consumed: bool,
}
#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct ApprovalIdInput {
    pub request_id: String,
}
#[derive(Clone, Debug, Serialize, Deserialize, JsonSchema, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct ApprovalDecideInput {
    pub request_id: String,
    pub decision: ApprovalDecision,
    pub intent_hash: String,
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn secrets_and_unknown_events_are_not_valid_wire_fields() {
        assert!(serde_json::from_value::<ProviderAuthentication>(
            serde_json::json!({"kind":"api_key","credential_ref":"ref","key":"secret"})
        )
        .is_err());
        assert!(serde_json::from_value::<SessionEvent>(
            serde_json::json!({"seq":0,"type":"shell/execute","data":{}})
        )
        .is_err());
    }
}
