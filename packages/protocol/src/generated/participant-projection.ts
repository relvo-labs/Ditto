/* Generated from schema/participant-projection.json; do not edit. */

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
export type HotSwapLevel = 'instant' | 'controlled_handoff' | 'host_restart' | 'session_restart';

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
  rules?: LayoutRule[];
  /**
   * @minItems 2
   * @maxItems 2
   */
  workspace_grid: [number, number];
}
export interface LayoutRule {
  match: LayoutMatch;
  workspace: number;
}
export interface LayoutMatch {
  app_id: string;
}
