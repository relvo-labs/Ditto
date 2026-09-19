/* Generated from schema/window-set-state-input.json; do not edit. */

export type WindowState = 'normal' | 'minimized' | 'maximized' | 'fullscreen';
/**
 * An opaque identifier valid only for the current compositor session.
 */
export type WindowSessionId = string;

export interface WindowSetStateInput {
  state: WindowState;
  window_id: WindowSessionId;
}
