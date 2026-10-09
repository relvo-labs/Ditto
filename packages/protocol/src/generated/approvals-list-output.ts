/* Generated from schema/approvals-list-output.json; do not edit. */

export type ApprovalDecision = 'allowed-once' | 'rejected' | 'cancelled' | 'unavailable';

export interface ApprovalsListOutput {
  /**
   * Undecided, unexpired requests the caller may see.
   */
  approvals: Approval[];
}
export interface Approval {
  consumed: boolean;
  decision?: ApprovalDecision | null;
  expires_at_ms: number;
  generation: string;
  principal: string;
  request: ApprovalRequestInput;
  request_id: string;
  /**
   * What the call would act on, as Core reads it (a Profile's name), so
   * the person sees the target from Core's record, not the model's words.
   */
  target?: string | null;
}
export interface ApprovalRequestInput {
  /**
   * The bound tool call's arguments, for a capability whose ask names its
   * target (deleting a Profile). Core checks them against `intent_hash`,
   * derives `Approval::target` and does not keep them.
   */
  arguments?: {
    [k: string]: unknown;
  };
  capability_id: string;
  intent_hash: string;
  purpose: string;
  resource: string;
  session_id: string;
  turn_id: string;
}
