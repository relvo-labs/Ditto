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
