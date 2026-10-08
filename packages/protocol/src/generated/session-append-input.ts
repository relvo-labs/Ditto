/* Generated from schema/session-append-input.json; do not edit. */

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

export interface SessionAppendInput {
  batch_id: string;
  events: SessionEvent[];
  expected_next_seq: number;
  session_id: string;
  writer_lease: string;
}
export interface SessionEvent {
  data: unknown;
  seq: number;
  type: SessionEventKind;
}
