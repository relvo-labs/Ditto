/* Generated from schema/turn-claim-output.json; do not edit. */

export type ContextKind = 'file' | 'clipboard' | 'capture';
export type DiffKind = 'added' | 'removed' | 'changed';
export type ResultKind = ('succeeded' | 'failed' | 'partial' | 'unknown') | 'scheduled';
export type ChangeState =
  | 'draft'
  | 'validated'
  | 'rejected'
  | 'prepared'
  | 'aborted'
  | 'applying'
  | 'verifying'
  | 'committed'
  | 'rolling_back'
  | 'rolled_back'
  | 'partially_applied'
  | 'unknown';
export type ProviderAuthentication =
  | {
      connection_ref: string;
      kind: 'codex_subscription';
    }
  | {
      credential_ref: string;
      kind: 'api_key';
    };
export type TurnState =
  | 'queued'
  | 'running'
  | 'awaiting_approval'
  | 'cancelling'
  | 'succeeded'
  | 'failed'
  | 'partial'
  | 'unknown'
  | 'cancelled';

export interface TurnClaimOutput {
  /**
   * Context attached to this turn's message and still held by Core.
   * A reference whose content was released (expiry, Core restart) is
   * absent: the Agent says so instead of guessing.
   */
  contexts?: ContextPayload[];
  message_seq: number;
  /**
   * The latest ChangeSets this conversation produced, newest first, as
   * Core recorded them: what "that", "it" or "a bit more" can refer to.
   */
  recent_changes?: RecentChange[];
  settings: AgentPreferences;
  text: string;
  turn: Turn;
}
/**
 * Context content handed to the Agent for the one turn it was attached to.
 */
export interface ContextPayload {
  /**
   * `data:image/png;base64,…`
   */
  image_data_url?: string | null;
  reference: ContextReference;
  text?: string | null;
}
/**
 * What a piece of context is, without its content. This is what a
 * conversation keeps; the content lives in Core's memory until released.
 */
export interface ContextReference {
  bytes: number;
  captured_at: string;
  context_id: string;
  expires_at_ms: number;
  kind: ContextKind;
  /**
   * A file name (never its path), "clipboard" or an output name.
   */
  label: string;
  mime: string;
  sha256: string;
  /**
   * The content was cut at the size limit.
   */
  truncated: boolean;
}
export interface RecentChange {
  change_id: string;
  items: DiffItem[];
  result?: ResultKind | null;
  state: ChangeState;
  turn_id: string;
}
/**
 * One line of a change card. The label is a translation key so Core never
 * emits locale-specific text; the Shell renders it in the Profile's language.
 */
export interface DiffItem {
  after?: unknown;
  before?: unknown;
  kind: DiffKind;
  label_args?: {
    [k: string]: unknown;
  };
  label_key: string;
  path: string;
}
export interface AgentPreferences {
  /**
   * `ask`: an Agent call outside its grants asks the person once.
   * `never`: nobody is asked; such calls are refused (existing grants
   * still apply). Never an automatic yes.
   */
  approval_mode?: 'ask' | 'never';
  auth?: ProviderAuthentication | null;
  enabled: boolean;
  /**
   * `direct-model` only: the OpenAI-compatible Responses endpoint
   * (`https://…/v1`). Its key is the `api_key` credential reference.
   */
  endpoint?: string | null;
  max_tool_calls: number;
  model?: string | null;
  provider: string;
  reasoning_effort?: string | null;
  retain_conversations: boolean;
  revision: number;
  turn_timeout_ms: number;
}
export interface Turn {
  created_at: string;
  error_reason?: string | null;
  operation_ids: string[];
  session_id: string;
  settings_revision: number;
  state: TurnState;
  tool_calls: number;
  turn_id: string;
}
