/* Generated from schema/host-invoke-params.json; do not edit. */

export interface InvokeParams {
  caller: string;
  capability_id: string;
  deadline_ms: number;
  entry_id: string;
  input: unknown;
  lease_id: string;
  operation_id?: string | null;
}
