/* Generated from schema/result-meta.json; do not edit. */

export interface ResultMeta {
  /**
   * Core's monotonic time, in microseconds, from reading the request to
   * writing this result. For a write with `readback_verified`, it spans
   * acceptance to the completed readback (the NFR-03 measure); it is
   * Core's own clock, not the caller's round trip.
   */
  handled_us?: number | null;
  /**
   * Set when a cancellation arrived for a capability declared
   * non-cancellable: the request ran to completion and was not cancelled.
   */
  not_cancellable?: boolean | null;
  /**
   * Observation sequence of the event stream (the G0 meaning of revision).
   */
  observed_seq: number;
  /**
   * Head revision of the active Profile, `null` before one is loaded.
   */
  profile_revision?: string | null;
  readback_verified: boolean;
}
