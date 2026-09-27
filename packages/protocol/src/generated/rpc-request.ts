/* Generated from schema/rpc-request.json; do not edit. */

export interface RpcRequest {
  /**
   * Absent on notifications. Ids Core itself issues start with `core-`; a
   * client may not use that prefix for its own requests.
   */
  id?: string | null;
  jsonrpc: string;
  method: string;
  params: unknown;
}
