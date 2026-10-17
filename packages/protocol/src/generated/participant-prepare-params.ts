/* Generated from schema/participant-prepare-params.json; do not edit. */

export type Projection =
  | {
      appearance: Appearance;
      avatar: AvatarSettings;
      role: 'shell';
      shortcuts: ShortcutBinding[];
      slots: ShellSlotBinding[];
    }
  | {
      entries: HostEntryProjection[];
      role: 'hostd';
    }
  | {
      layout: LayoutIntent;
      role: 'compositor';
      shortcuts: ShortcutBinding[];
      /**
       * Package of the `layout.strategy` provider.
       */
      strategy?: string | null;
    };
/**
 * An explicit rendering choice; absence retains the optional legacy avatar.
 */
export type AvatarPresentation = 'assistant';
export type HotSwapLevel = 'instant' | 'controlled_handoff' | 'host_restart' | 'session_restart';

export interface PrepareParams {
  change_id: string;
  origin: string;
  target: Projection;
  /**
   * Set when this change undoes an earlier one: a participant that kept
   * state outside the profile for that change (window placement before a
   * layout strategy switch) restores it and reports what it could not.
   */
  undoes?: string | null;
}
export interface Appearance {
  locale: string;
  /**
   * No blur and no shadow; NFR-05 measures it as its own style.
   */
  low_power_style?: boolean;
  reduced_motion?: boolean;
  reduced_transparency?: boolean;
  theme: string;
  tokens?: {
    [k: string]: string;
  };
}
export interface AvatarSettings {
  animations?: boolean;
  /**
   * Which corner of that output the character sits in. A corner is always
   * inside the visible area, whatever size the output has.
   */
  corner?: 'bottom_right' | 'bottom_left' | 'top_right' | 'top_left';
  enabled: boolean;
  hidden?: boolean;
  /**
   * The output the character stays on, by connector name. Absent means
   * it follows the primary output; so does a named output that is not
   * connected (unplugged), until it comes back. Absent fields are left out
   * of the document, so a Profile written before they existed keeps its
   * digest.
   */
  output?: string | null;
  /**
   * D-48: absent preserves legacy rendering and its document digest.
   * Older readers reject this field; see the explicit downgrade policy.
   */
  presentation?: AvatarPresentation | null;
  scale: number;
}
export interface ShortcutBinding {
  chord: string;
  command: string;
}
export interface ShellSlotBinding {
  config: unknown;
  entry_id: string;
  package: string;
  /**
   * `file://` URL of the provider's `qml_entry` inside the package store.
   */
  qml_url: string;
  slot: string;
  version: string;
}
export interface HostEntryProjection {
  cleanup_timeout_ms: number;
  config: unknown;
  data_dir: string;
  disabled: boolean;
  entry_id: string;
  /**
   * File grants this entry holds, id → absolute path. The path is only
   * ever sent to the process that holds the grant, never exported.
   */
  file_grants?: {
    [k: string]: string;
  };
  health_timeout_ms: number;
  hot_swap: HotSwapLevel;
  module_path: string;
  package: string;
  provides: string[];
  version: string;
}
/**
 * Layout intent. Which strategy applies is the `layout.strategy` slot.
 */
export interface LayoutIntent {
  /**
   * Where windows of an application go, as a share of their output's work
   * area (D-40). Applied to the windows open when the change commits and to
   * those that open later; moving a window by hand afterwards is respected
   * until the next explicit change. Floating strategy only.
   */
  regions?: RegionRule[];
  rules?: LayoutRule[];
  /**
   * @minItems 2
   * @maxItems 2
   */
  workspace_grid: [number, number];
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
