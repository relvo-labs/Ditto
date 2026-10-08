/* Generated from schema/turn-claim-output.json; do not edit. */

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
  message_seq: number;
  settings: AgentPreferences;
  text: string;
  turn: Turn;
}
export interface AgentPreferences {
  auth?: ProviderAuthentication | null;
  enabled: boolean;
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
