/* Generated from schema/credential-status.json; do not edit. */

export interface CredentialStatus {
  /**
   * Resolvable now (present and the keyring is unlocked).
   */
  available: boolean;
  credential_ref: string;
  /**
   * `missing`, `locked` or `keyring_unavailable` when not available.
   */
  reason?: string | null;
}
