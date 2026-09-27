/* Generated from schema/policy-decide-output.json; do not edit. */

export type PolicyDecision = 'show' | 'merge' | 'silence';

export interface PolicyDecideOutput {
  decision: PolicyDecision;
  rule?: string | null;
}
