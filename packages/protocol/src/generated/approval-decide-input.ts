/* Generated from schema/approval-decide-input.json; do not edit. */

export type ApprovalDecision = 'allowed-once' | 'rejected' | 'cancelled' | 'unavailable';

export interface ApprovalDecideInput {
  decision: ApprovalDecision;
  intent_hash: string;
  request_id: string;
}
