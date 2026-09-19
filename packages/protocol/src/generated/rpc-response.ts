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
  message: string;
  name: ErrorName;
  outcome?: Outcome | null;
}
