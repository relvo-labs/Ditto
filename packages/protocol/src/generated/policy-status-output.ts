/* Generated from schema/policy-status-output.json; do not edit. */

/**
 * Why a capability or a call is unavailable. Closed: a consumer can show a
 * specific product sentence for every value.
 */
export type UnavailableReason =
  | (
      | 'compositor_offline'
      | 'host_unavailable'
      | 'host_crash_loop'
      | 'lease_expired'
      | 'not_bound'
      | 'rescue_mode'
      | 'recovering'
      | 'system_unavailable'
      | 'participant_unavailable'
      | 'session_locked'
    )
  | 'storage_full'
  | 'storage_error';
export type PolicyDecision = 'show' | 'merge' | 'silence';

export interface PolicyStatusOutput {
  available: boolean;
  counters?: PolicyCounters | null;
  /**
   * Decisions Core made itself (shown) because the policy was unreachable.
   */
  fallback_shown: number;
  provider_entry?: string | null;
  reason?: UnavailableReason | null;
  recent: PolicyRecord[];
}
export interface PolicyCounters {
  merge: number;
  show: number;
  silence: number;
}
export interface PolicyRecord {
  app_name: string;
  at: string;
  decision: PolicyDecision;
  rule?: string | null;
}
