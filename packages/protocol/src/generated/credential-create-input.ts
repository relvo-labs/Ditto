/* Generated from schema/credential-create-input.json; do not edit. */

/**
 * A new API key from the person's settings form. The value goes straight
 * to the Secret Service; Core answers with an opaque reference only.
 */
export interface CredentialCreateInput {
  idempotency_key: string;
  provider: string;
  secret: string;
}
