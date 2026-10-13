/* Generated from schema/layout-get-output.json; do not edit. */

export type HotSwapLevel = 'instant' | 'controlled_handoff' | 'host_restart' | 'session_restart';

export interface LayoutGetOutput {
  available: LayoutStrategyInfo[];
  observed_strategy?: string | null;
  /**
   * Session-restart changes waiting for the next login.
   */
  pending_next_login: string[];
  region_windows?: RegionWindow[];
  /**
   * Region rules of the Profile (D-40), with the open windows they cover
   * and where those windows are now.
   */
  regions?: RegionRule[];
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
export interface RegionWindow {
  app_id: string;
  /**
   * `[x, y, width, height]` in output-relative logical pixels.
   *
   * @minItems 4
   * @maxItems 4
   */
  geometry?: [number, number, number, number] | null;
  output?: string | null;
  rule_id: string;
  window_id: string;
}
export interface RegionRule {
  match: LayoutMatch;
  /**
   * The output whose work area the region divides; absent means the
   * output the window is on.
   */
  output?: string | null;
  region: Region;
  /**
   * Stable within the Profile, so a later turn can name "the same rule".
   */
  rule_id: string;
}
export interface LayoutMatch {
  app_id: string;
}
/**
 * A rectangle as fractions (0–1) of an output's work area.
 */
export interface Region {
  height: number;
  width: number;
  x: number;
  y: number;
}
export interface LayoutRule {
  match: LayoutMatch;
  workspace: number;
}
