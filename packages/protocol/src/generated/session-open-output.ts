/* Generated from schema/session-open-output.json; do not edit. */

export interface SessionOpenOutput {
  session: Conversation;
  writer_lease: string;
}
export interface Conversation {
  created_at: string;
  durable_seq: number;
  format_version: number;
  next_seq: number;
  session_id: string;
  title: string;
}
