/* Generated from schema/agent-preferences.json; do not edit. */

export type ProviderAuthentication =
  | {
      connection_ref: string;
      kind: 'codex_subscription';
    }
  | {
      credential_ref: string;
      kind: 'api_key';
    };

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
