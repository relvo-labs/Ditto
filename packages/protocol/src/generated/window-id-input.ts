/* Generated from schema/window-id-input.json; do not edit. */

/**
 * An opaque identifier valid only for the current compositor session.
 */
export type WindowSessionId = string;

export interface WindowIdInput {
  window_id: WindowSessionId;
}
