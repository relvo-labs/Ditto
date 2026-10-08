/* Generated from schema/approval.json; do not edit. */

export type ApprovalDecision = 'allowed-once' | 'rejected' | 'cancelled' | 'unavailable';

export interface Approval {
  consumed: boolean;
  decision?: ApprovalDecision | null;
  expires_at_ms: number;
  generation: string;
  principal: string;
  request: ApprovalRequestInput;
  request_id: string;
}
export interface ApprovalRequestInput {
  capability_id: string;
  intent_hash: string;
  purpose: string;
  resource: string;
  session_id: string;
  turn_id: string;
}
