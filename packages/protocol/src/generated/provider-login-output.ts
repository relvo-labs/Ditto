/* Generated from schema/provider-login-output.json; do not edit. */

export interface ProviderLoginOutput {
  /**
   * The device-code verification page the person opens in a browser.
   */
  auth_url: string;
  expires_at_ms: number;
  login_id: string;
  /**
   * The one-time code the person enters on that page.
   */
  user_code: string;
}
