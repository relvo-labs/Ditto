/* Generated from schema/permissions-grant-input.json; do not edit. */

export interface PermissionsGrantInput {
  expires_at?: string | null;
  idempotency_key: string;
  resource?: string | null;
  scope: string;
  subject: string;
}
