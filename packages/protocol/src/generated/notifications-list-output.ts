/* Generated from schema/notifications-list-output.json; do not edit. */

export type PolicyDecision = 'show' | 'merge' | 'silence';
export type Urgency = 'low' | 'normal' | 'critical';

export interface NotificationsListOutput {
  notifications: NotificationItem[];
  server_owned: boolean;
}
export interface NotificationItem {
  app_name: string;
  body: string;
  created_at: string;
  decision: PolicyDecision;
  id: number;
  merged_count: number;
  /**
   * Set when the policy could not be asked: the notification is shown and
   * the area says rules are unavailable (failing open to display).
   */
  policy_unavailable: boolean;
  summary: string;
  urgency: Urgency;
}
