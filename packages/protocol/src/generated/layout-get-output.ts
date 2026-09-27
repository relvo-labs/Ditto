/* Generated from schema/layout-get-output.json; do not edit. */

export type HotSwapLevel = 'instant' | 'controlled_handoff' | 'host_restart' | 'session_restart';

export interface LayoutGetOutput {
  available: LayoutStrategyInfo[];
  observed_strategy?: string | null;
  /**
   * Session-restart changes waiting for the next login.
   */
  pending_next_login: string[];
  rules: LayoutRule[];
  strategy_entry?: string | null;
  strategy_package?: string | null;
  /**
   * @minItems 2
   * @maxItems 2
   */
  workspace_grid: [number, number];
}
export interface LayoutStrategyInfo {
  hot_swap: HotSwapLevel;
  name_key: string;
  package: string;
  /**
   * False when the compositor cannot switch it while running (C-15): the
   * switch is then scheduled for the next login and says so.
   */
  runtime_switchable: boolean;
}
export interface LayoutRule {
  match: LayoutMatch;
  workspace: number;
}
export interface LayoutMatch {
  app_id: string;
}
