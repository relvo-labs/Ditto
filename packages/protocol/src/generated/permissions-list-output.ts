/* Generated from schema/permissions-list-output.json; do not edit. */

export interface PermissionsListOutput {
  grants: Grant[];
  policy: PolicyRow[];
}
export interface Grant {
  expires_at?: string | null;
  grant_id: string;
  granted_at: string;
  granted_by: string;
  /**
   * For `files:` grants the Shell shows the file name, never the path, in
   * exports; the path itself only reaches the process holding the grant.
   */
  resource?: string | null;
  revoked_at?: string | null;
  scope: string;
  subject: string;
}
export interface PolicyRow {
  /**
   * `allowed`, `denied` or `grant_required`.
   */
  default: string;
  scope: string;
  subject_kind: string;
}
