/* Generated from schema/participant-observation.json; do not edit. */

export type Observation =
  | {
      appearance?: Appearance | null;
      avatar?: AvatarSettings | null;
      mounts: PanelMount[];
      role: 'shell';
    }
  | {
      entries: HostEntryObservation[];
      role: 'hostd';
    }
  | {
      role: 'compositor';
      shortcuts: ShortcutBinding[];
      strategy?: string | null;
      /**
       * @minItems 2
       * @maxItems 2
       */
      workspace_grid?: [number, number] | null;
    };
export type FiberState = 'pending' | 'loading' | 'active' | 'unloading' | 'disposed' | 'failed';
export type EntryMode = 'candidate' | 'active';

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
  enabled: boolean;
  hidden?: boolean;
  scale: number;
}
export interface PanelMount {
  entry_id: string;
  mounted: boolean;
  slot: string;
  visible: boolean;
}
export interface HostEntryObservation {
  entry_id: string;
  failure?: string | null;
  fiber_state: FiberState;
  mode: EntryMode;
  waiting_for?: string[];
}
export interface ShortcutBinding {
  chord: string;
  command: string;
}
