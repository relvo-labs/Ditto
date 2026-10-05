/* Generated from schema/panels-list-output.json; do not edit. */

/**
 * Where on its output the character sits.
 */
export type AvatarCorner = 'bottom_right' | 'bottom_left' | 'top_right' | 'top_left';

export interface PanelsListOutput {
  /**
   * Where the Shell last reported the character to be; absent when no
   * Shell has reported a placement. This is the character's readback.
   */
  avatar?: AvatarPlacement | null;
  panels: PanelStatus[];
  reported_at?: string | null;
  shell_connected: boolean;
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
export interface PanelStatus {
  bound_entry?: string | null;
  mounted: boolean;
  mounted_entry?: string | null;
  package?: string | null;
  slot: string;
  visible: boolean;
}
