/* Generated from schema/grant.json; do not edit. */

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
