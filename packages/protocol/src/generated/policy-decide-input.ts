/* Generated from schema/policy-decide-input.json; do not edit. */

export type Urgency = 'low' | 'normal' | 'critical';

/**
 * What Core asks the `svc.notification_policy` provider, with a 50 ms
 * deadline. Body text is not sent: the rules do not need it.
 */
export interface PolicyDecideInput {
  app_name: string;
  at: string;
  urgency: Urgency;
}
