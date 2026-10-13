/* Generated from schema/session-event.json; do not edit. */

/**
 * Restricted Harness vocabulary (pinned 477b4f4); unknown required events
 * refuse decoding rather than silently reconstructing a different history.
 */
export type SessionEventKind =
  | 'user/message'
  | 'assistant/message'
  | 'turn/start'
  | 'turn/end'
  | 'tool/call'
  | 'tool/result'
  | 'approval/asked'
  | 'approval/decided'
  | 'model/selection'
  | 'compaction/summary'
  | 'session/title'
  | 'request/context';

export interface SessionEvent {
  data: unknown;
  seq: number;
  type: SessionEventKind;
}
