/* Generated from schema/window-resize-input.json; do not edit. */

/**
 * An opaque identifier valid only for the current compositor session.
 */
export type WindowSessionId = string;

export interface WindowResizeInput {
  height: number;
  width: number;
  window_id: WindowSessionId;
}
