/* Generated from schema/rpc-response.json; do not edit. */

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
export type Outcome = 'unknown';

export interface RpcResponse {
  error?: RpcError | null;
  id: string;
  jsonrpc: string;
  result?: unknown;
}
export interface RpcError {
  code: number;
  /**
   * Reason codes and translation keys, never product text: `reason` for
   * `unavailable`, `conflict` and `permission_denied`; `reasons[]` for
   * `preflight_rejected`.
   */
  data?: {
    [k: string]: unknown;
  };
  message: string;
  name: ErrorName;
  outcome?: Outcome | null;
}
