/* Generated from schema/result-meta.json; do not edit. */

export interface ResultMeta {
  /**
   * Set when a cancellation arrived for a capability declared
   * non-cancellable: the request ran to completion and was not cancelled.
   */
  not_cancellable?: boolean | null;
  readback_verified: boolean;
  /**
   * Observation sequence, not a persistent Profile revision in G0.
   */
  revision: number;
}
