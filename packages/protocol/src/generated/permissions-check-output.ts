/* Generated from schema/permissions-check-output.json; do not edit. */

export type Decision = 'allowed' | 'denied' | 'needs_approval';
export type PermissionDeniedReason = ('not_granted' | 'policy_denied') | 'approval_unavailable';

export interface PermissionsCheckOutput {
  decision: Decision;
  /**
   * What a call would actually get: G1 has no approval responder, so
   * `needs_approval` is refused as `approval_unavailable`.
   */
  effective: 'allowed' | 'denied' | 'needs_approval';
  reason?: PermissionDeniedReason | null;
  scopes: string[];
}
