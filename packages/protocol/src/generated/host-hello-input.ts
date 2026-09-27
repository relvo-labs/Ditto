/* Generated from schema/host-hello-input.json; do not edit. */

export type CandidateStrategy = 'isolate_rebuild' | 'in_place';

export interface HelloInput {
  cordis_version: string;
  hostd_version: string;
  node_version: string;
  strategy: CandidateStrategy;
  vendor_fingerprint: string;
}
