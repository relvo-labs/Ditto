/* Generated from schema/rescue-disable-input.json; do not edit. */

/**
 * Rescue actions work on the Profile only; they need no plugin code.
 */
export interface RescueDisableInput {
  idempotency_key?: string | null;
  /**
   * An entry id, or a package id (every entry of that package).
   */
  target: string;
}
