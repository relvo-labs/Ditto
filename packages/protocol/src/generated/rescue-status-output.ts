/* Generated from schema/rescue-status-output.json; do not edit. */

export type CoreMode = 'normal' | 'rescue';
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

export interface RescueStatusOutput {
  active_profile?: string | null;
  head_revision?: string | null;
  host: HostStatus;
  last_known_good?: string | null;
  mode: CoreMode;
  /**
   * Changes whose outcome boot recovery decided, newest first.
   */
  recovered_changes: string[];
  shell_connected: boolean;
  /**
   * Capabilities that depend on Cordis and are not offered right now; the
   * Shell says so in product language instead of letting them vanish.
   */
  unavailable: UnavailableCapability[];
}
export interface HostStatus {
  generation?: number | null;
  heap?: NodeHeap | null;
  process?: ProcessResources | null;
  restarts_last_10_min: number;
  /**
   * `running`, `starting`, `stopped`, `crash_loop`, `not_needed`, `rescue_mode`.
   */
  state: string;
  strategy?: string | null;
  versions: {
    [k: string]: string;
  };
}
export interface NodeHeap {
  array_buffers: number;
  external: number;
  heap_used: number;
}
/**
 * Process-level figures Core read from `/proc`; hostd's own report is only
 * used for the Node heap, listed separately and never added to these.
 */
export interface ProcessResources {
  cpu_ticks?: number | null;
  fds?: number | null;
  pid: number;
  pss_kib?: number | null;
  rss_kib?: number | null;
  threads?: number | null;
}
export interface UnavailableCapability {
  capability_id: string;
  reason: UnavailableReason;
}
