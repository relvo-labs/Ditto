/* Generated from schema/session-read-output.json; do not edit. */

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

export interface SessionReadOutput {
  events: SessionEvent[];
  session: Conversation;
}
export interface SessionEvent {
  data: unknown;
  seq: number;
  type: SessionEventKind;
}
export interface Conversation {
  created_at: string;
  durable_seq: number;
  format_version: number;
  next_seq: number;
  session_id: string;
  title: string;
}
