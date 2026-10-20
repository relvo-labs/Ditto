/* Generated from schema/appearance-get-output.json; do not edit. */

/**
 * An explicit rendering choice; absence retains the optional legacy avatar.
 */
export type AvatarPresentation = 'assistant';
/**
 * What an appearance token holds. Every token is stored as a string.
 */
export type TokenKind = 'color' | 'number' | 'text';

export interface AppearanceGetOutput {
  appearance: Appearance;
  avatar: AvatarSettings;
  profile_revision: string;
  /**
   * What the Shell last reported as applied; `null` when no Shell reported.
   */
  shell_applied?: Appearance | null;
  /**
   * Every token `desktop.appearance.set` accepts, with its kind, the
   * default in effect while `appearance.tokens` has no value, and range.
   */
  tokens_available: AppearanceToken[];
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
/**
 * One appearance token the Shell reads (`shell/jelly/Tokens.qml`).
 */
export interface AppearanceToken {
  /**
   * The only values a text token takes, when it is a closed choice
   * (`ui_style`). Absent for every other token.
   */
  choices?: string[] | null;
  /**
   * What the Shell uses while the Profile sets no value.
   */
  default: string;
  description: string;
  kind: TokenKind;
  max?: number | null;
  min?: number | null;
  name: string;
}
