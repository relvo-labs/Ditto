/* Generated from schema/events-subscribe-input.json; do not edit. */

export type EventTopic = 'desktop' | 'changes' | 'plugins' | 'notifications' | 'tasks' | 'session';

export interface EventsSubscribeInput {
  after_seq?: number | null;
  /**
   * Absent means `["desktop"]`, the G0 stream. Each topic needs its own
   * scope, so asking for more than the caller may read is refused whole.
   */
  topics?: EventTopic[] | null;
}
