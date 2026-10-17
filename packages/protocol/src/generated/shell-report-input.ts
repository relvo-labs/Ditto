/* Generated from schema/shell-report-input.json; do not edit. */

/**
 * An explicit rendering choice; absence retains the optional legacy avatar.
 */
export type AvatarPresentation = 'assistant';
/**
 * Where on its output the character sits.
 */
export type AvatarCorner = 'bottom_right' | 'bottom_left' | 'top_right' | 'top_left';

export interface ShellObservation {
  appearance?: Appearance | null;
  /**
   * The Shell shows approval requests and can answer them. Without it an
   * Agent's approval request is recorded as unavailable at once: nobody
   * would see it, and waiting would only stall the turn.
   */
  approval_responder?: boolean;
  avatar?: AvatarSettings | null;
  /**
   * Where the character actually is, as the Shell laid it out. `avatar`
   * above echoes the settings; this is the readback of their effect.
   */
  avatar_placement?: AvatarPlacement | null;
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
  /**
   * Where on its output the character sits.
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
/**
 * The character's placement as the Shell observes it after laying it out.
 */
export interface AvatarPlacement {
  corner: AvatarCorner;
  /**
   * True when the Profile names no output, or names one that is not
   * connected, and the character is on the primary output instead.
   */
  follows_primary: boolean;
  height: number;
  /**
   * The output the character's surface is on; absent when it has no
   * surface (turned off, or no output connected).
   */
  output?: string | null;
  /**
   * On screen: false while hidden or turned off.
   */
  visible: boolean;
  width: number;
  /**
   * The surface rectangle in logical pixels, relative to `output`.
   */
  x: number;
  y: number;
}
export interface PanelMount {
  /**
   * Identity read from the mounted fixed-template instance, never merely
   * copied from the requested projection. Required to verify G3 upgrades.
   */
  artifact_id?: string | null;
  entry_id: string;
  mounted: boolean;
  slot: string;
  visible: boolean;
}
