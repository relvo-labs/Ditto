/* Generated from schema/window-move-input.json; do not edit. */

/**
 * An opaque identifier valid only for the current compositor session.
 */
export type WindowSessionId = string;

export interface WindowMoveInput {
  window_id: WindowSessionId;
  x: number;
  y: number;
}
