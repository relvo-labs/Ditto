/* Generated from schema/provider-login-result.json; do not edit. */

export type ProviderLoginState = 'pending' | 'succeeded' | 'failed' | 'cancelled' | 'expired' | 'unknown';

export interface ProviderLoginResult {
  generation: number;
  login_id: string;
  state: ProviderLoginState;
}
