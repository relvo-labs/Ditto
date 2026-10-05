/* Generated from schema/capabilities-list-output.json; do not edit. */

export type Availability =
  | {
      kind: 'always';
      [k: string]: unknown;
    }
  | {
      kind: 'resolved_at_runtime';
      matrix_row?: string | null;
      slot?: string | null;
      [k: string]: unknown;
    }
  | {
      available: boolean;
      /**
       * Compositor-specific path this capability is bound to, when no
       * neutral Wayland protocol covers it.
       */
      bound_to?: string | null;
      kind: 'depends_on_compositor';
      matrix_row: string;
      reason?: string | null;
      [k: string]: unknown;
    }
  | {
      available: boolean;
      entry_id?: string | null;
      kind: 'depends_on_provider';
      reason?: UnavailableReason | null;
      slot: string;
      [k: string]: unknown;
    }
  | {
      available: boolean;
      component: string;
      kind: 'depends_on_system';
      reason?: UnavailableReason | null;
      [k: string]: unknown;
    };
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
export type ErrorName =
  | 'unsupported'
  | 'invalid_params'
  | 'not_found'
  | 'permission_denied'
  | 'timeout'
  | 'cancelled'
  | 'conflict'
  | 'unavailable'
  | 'protocol_version_unsupported'
  | 'identity_rejected'
  | 'preflight_rejected'
  | 'internal';
export type Idempotency = 'none' | 'key-based' | 'natural';

export interface CapabilitiesListOutput {
  capabilities: CapabilityDescriptor[];
  catalog_revision: number;
}
/**
 * A capability contract. `availability` is the only runtime-resolved field:
 * the exported catalog declares what a capability depends on (a matrix row
 * or a provider slot), and Core fills in what is actually offered.
 */
export interface CapabilityDescriptor {
  availability: Availability;
  cancellable: boolean;
  capability_id: string;
  claimable: boolean;
  errors: ErrorName[];
  idempotency: Idempotency;
  input_schema: unknown;
  output_schema: unknown;
  /**
   * `core`, `compositor-adapter`, `system`, `shell` or `hostd`; the
   * served catalog names the entry: `hostd:<entry_id>`.
   */
  provider: string;
  readback?: string | null;
  /**
   * Never empty from 0.2 on: every call goes through one authorization
   * entry point, and an empty scope would be an unreviewed default.
   */
  resource_scope: string[];
  timeout_ms: Timeout;
  version: string;
}
export interface Timeout {
  default_ms: number;
  max_ms: number;
}
