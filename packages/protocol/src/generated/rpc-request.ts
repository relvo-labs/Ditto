/* Generated from schema/rpc-request.json; do not edit. */

export interface RpcRequest {
  /**
   * Absent on notifications; `$/cancel` is the only notification G0 accepts.
   */
  id?: string | null;
  jsonrpc: string;
  method: string;
  params: unknown;
}
