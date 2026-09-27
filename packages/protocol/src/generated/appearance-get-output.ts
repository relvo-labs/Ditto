/* Generated from schema/appearance-get-output.json; do not edit. */

export interface AppearanceGetOutput {
  appearance: Appearance;
  avatar: AvatarSettings;
  profile_revision: string;
  /**
   * What the Shell last reported as applied; `null` when no Shell reported.
   */
  shell_applied?: Appearance | null;
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
