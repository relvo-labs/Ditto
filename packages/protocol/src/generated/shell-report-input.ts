/* Generated from schema/shell-report-input.json; do not edit. */

export interface ShellObservation {
  appearance?: Appearance | null;
  avatar?: AvatarSettings | null;
  mounts: PanelMount[];
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
