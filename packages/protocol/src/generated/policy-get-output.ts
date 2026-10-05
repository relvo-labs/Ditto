/* Generated from schema/policy-get-output.json; do not edit. */

export type PolicyDecision = 'show' | 'merge' | 'silence';

export interface PolicyGetOutput {
  counters: PolicyCounters;
  recent: PolicyRecord[];
  rules: unknown;
}
export interface PolicyCounters {
  merge: number;
  show: number;
  silence: number;
}
export interface PolicyRecord {
  app_name: string;
  at: string;
  decision: PolicyDecision;
  rule?: string | null;
}
