/* Generated from schema/provider-login-result-input.json; do not edit. */

/**
 * Readback of one ephemeral authorization attempt, never account authority.
 */
export interface ProviderLoginResultInput {
  /**
   * Core's runtime generation observed by the caller when login started.
   */
  generation: number;
  login_id: string;
  provider: string;
}
