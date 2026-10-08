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
  /**
   * `ask`: an Agent call outside its grants asks the person once.
   * `never`: nobody is asked; such calls are refused (existing grants
   * still apply). Never an automatic yes.
   */
  approval_mode?: 'ask' | 'never';
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
