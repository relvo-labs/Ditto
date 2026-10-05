/* Generated from schema/host-hello-output.json; do not edit. */

export type CoreMode = 'normal' | 'rescue';

export interface HelloOutput {
  heartbeat_interval_ms: number;
  host_generation: number;
  lease_ttl_ms: number;
  mode: CoreMode;
}
