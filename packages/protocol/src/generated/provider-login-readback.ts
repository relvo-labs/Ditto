/* Generated from schema/provider-login-readback.json; do not edit. */

export type ProviderLoginState = 'pending' | 'succeeded' | 'failed' | 'cancelled' | 'expired' | 'unknown';

/**
 * Controller-only envelope. Core rechecks the original absolute deadline
 * after awaiting the controller; the public capability returns only `result`.
 */
export interface ProviderLoginReadback {
  expires_at_ms?: number | null;
  result: ProviderLoginResult;
}
export interface ProviderLoginResult {
  generation: number;
  login_id: string;
  state: ProviderLoginState;
}
