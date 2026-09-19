/* Generated from schema/capabilities-list-output.json; do not edit. */

export type Availability =
  | {
      kind: 'always';
      [k: string]: unknown;
    }
  | {
      kind: 'resolved_at_runtime';
      matrix_row: string;
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
    };
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
  | 'internal';
export type Idempotency = 'none' | 'key-based' | 'natural';

export interface CapabilitiesListOutput {
  capabilities: CapabilityDescriptor[];
  catalog_revision: number;
}
/**
 * A capability contract. `availability` is the only runtime-resolved field:
 * the exported catalog declares which matrix row a capability depends on, and
 * Core fills in what the connected compositor actually offers.
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
  provider: string;
  readback?: string | null;
  resource_scope: string[];
  timeout_ms: Timeout;
  version: string;
}
export interface Timeout {
  default_ms: number;
  max_ms: number;
}
