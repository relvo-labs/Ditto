/* Generated from schema/approval-request-input.json; do not edit. */

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
