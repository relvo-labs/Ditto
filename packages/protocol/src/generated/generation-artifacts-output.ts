/* Generated from schema/generation-artifacts-output.json; do not edit. */

export type Content =
  | {
      max_items: number;
      order: TaskOrder;
      show_completed: boolean;
      template: 'tasks_summary_v1';
    }
  | {
      /**
       * @minItems 1
       * @maxItems 16
       */
      actions:
        | [WorkspaceAction]
        | [WorkspaceAction, WorkspaceAction]
        | [WorkspaceAction, WorkspaceAction, WorkspaceAction]
        | [WorkspaceAction, WorkspaceAction, WorkspaceAction, WorkspaceAction]
        | [WorkspaceAction, WorkspaceAction, WorkspaceAction, WorkspaceAction, WorkspaceAction]
        | [WorkspaceAction, WorkspaceAction, WorkspaceAction, WorkspaceAction, WorkspaceAction, WorkspaceAction]
        | [
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction
          ]
        | [
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction
          ]
        | [
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction
          ]
        | [
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction
          ]
        | [
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction
          ]
        | [
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction
          ]
        | [
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction
          ]
        | [
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction
          ]
        | [
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction
          ]
        | [
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction
          ];
      template: 'workspace_actions_v1';
    };
export type TaskOrder = 'source' | 'title';
export type DataType = 'text' | 'integer' | 'boolean' | 'text_list';
export type RollbackPolicy = 'snapshot' | 'compatible' | 'unavailable';
export type Coalesce = 'none' | 'latest';
export type HostKind = 'qml' | 'cordis' | 'core_builtin';
export type HotSwapLevel = 'instant' | 'controlled_handoff' | 'host_restart' | 'session_restart';
export type IdlePolicy = 'resident' | 'on_demand';
export type PluginKind = 'service' | 'qml_provider' | 'declarative_bundle';
export type TrustLevel = 'trusted' | 'community' | 'untrusted';
export type ArtifactState =
  'candidate' | 'validating' | 'inspect_only' | 'validated' | 'published' | 'active' | 'failed';
export type Enforcement = 'full' | 'partial' | 'unavailable';
export type StageResult = 'passed' | 'failed' | 'not_run';
export type ValidationStage = 'syntax' | 'contract' | 'load' | 'focus' | 'interaction';

export interface ArtifactsOutput {
  artifacts: GeneratedArtifact[];
}
export interface GeneratedArtifact {
  activations: ActivationRecord[];
  artifact_id: string;
  bundle_sha256: string;
  changed_fields: string[];
  config_schema: unknown;
  created_at: string;
  dependencies: {
    [k: string]: string;
  };
  description: Description;
  manifest: Manifest;
  origin: GenerationOrigin;
  parent_id?: string | null;
  previews?: PreviewRecord[];
  repair: RepairBudget;
  source_files: {
    [k: string]: string;
  };
  state: ArtifactState;
  validation?: GenerationValidation | null;
  validation_job_id?: string | null;
}
export interface ActivationRecord {
  at: string;
  change_id: string;
  revision?: string | null;
  state: string;
}
export interface Description {
  accent: string;
  content: Content;
  data?: DataPlan;
  format_version: number;
  plugin_id: string;
  title: string;
  version: string;
  width: number;
}
export interface WorkspaceAction {
  label: string;
  workspace_id: string;
}
export interface DataPlan {
  fields?: {
    [k: string]: DataType;
  };
  migration?: DataMigration | null;
  schema_version: number;
}
export interface DataMigration {
  defaults?: {
    [k: string]: unknown;
  };
  from_version: number;
  remove?: string[];
  rename?: {
    [k: string]: string;
  };
  rollback: RollbackPolicy;
}
export interface Manifest {
  activation_events?: string[];
  author: string;
  cleanup: TimeoutDecl;
  commands?: CommandDecl[];
  config_schema?: {
    [k: string]: unknown;
  };
  conflicts?: string[];
  data_schema?: unknown;
  description?: unknown;
  entry?: string | null;
  events?: EventDecl[];
  health: TimeoutDecl;
  host_kind: HostKind;
  hot_swap: HotSwapLevel;
  id: string;
  idle_policy: IdlePolicy;
  license: string;
  manifest_version: number;
  migrations?: unknown[];
  /**
   * A string, or a `{ locale: text }` object.
   */
  name: {
    [k: string]: unknown;
  };
  optional?: Item[];
  permissions?: string[];
  platform?: string[];
  plugin_kind: PluginKind;
  provides?: Item[];
  qml_entry?: string | null;
  required_protocol_version: string;
  requires?: Item[];
  rescue?: RescueDecl;
  resource_budget?: ResourceBudget;
  runtime?: RuntimeRequirement;
  settings_page?: SettingsPageDecl | null;
  shortcuts?: ShortcutDecl[];
  slots?: string[];
  source: string;
  trust_level: TrustLevel;
  version: string;
}
export interface TimeoutDecl {
  timeout_ms: number;
}
export interface CommandDecl {
  id: string;
  title_key: string;
}
export interface EventDecl {
  coalesce: Coalesce;
  name: string;
  schema: unknown;
}
/**
 * What a package provides or depends on. Exactly one field is set.
 */
export interface Item {
  capability?: string | null;
  package?: string | null;
  service?: string | null;
  /**
   * semver range, for `package` dependencies.
   */
  version?: string | null;
}
export interface RescueDecl {
  disable_safe?: boolean;
}
export interface ResourceBudget {
  cpu_percent?: number | null;
  memory_mib?: number | null;
}
export interface RuntimeRequirement {
  node?: string | null;
  qt?: string | null;
}
export interface SettingsPageDecl {
  category?: string | null;
  order: number;
  page_id: string;
  title_key: string;
}
export interface ShortcutDecl {
  chord: string;
  command: string;
}
export interface GenerationOrigin {
  model?: string | null;
  request_summary: string;
  turn_id?: string | null;
}
export interface PreviewRecord {
  at: string;
  job_id: string;
  opened: boolean;
  state: string;
}
export interface RepairBudget {
  attempts: number;
  failure_fingerprints: string[];
  stopped: boolean;
}
export interface GenerationValidation {
  boundary: GenerationBoundary;
  bundle_sha256: string;
  diagnostics?: string[];
  preview_opened: boolean;
  stages: StageEvidence[];
  test_data: boolean;
}
export interface GenerationBoundary {
  cgroup?: string | null;
  cleanup_complete: boolean;
  cpu_max: string;
  deadline_ms: number;
  enforcement: Enforcement;
  files: boolean;
  landlock_abi: number;
  memory_max: number;
  network: boolean;
  pids_max: number;
  policy: string;
  process_exec_blocked: boolean;
  reasons: string[];
  runner_pid?: number | null;
  unit?: string | null;
}
export interface StageEvidence {
  diagnostic: string;
  result: StageResult;
  stage: ValidationStage;
}
