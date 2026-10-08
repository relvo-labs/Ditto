/* Generated from schema/sessions-list-output.json; do not edit. */

export interface SessionsListOutput {
  sessions: Conversation[];
}
export interface Conversation {
  created_at: string;
  durable_seq: number;
  format_version: number;
  next_seq: number;
  session_id: string;
  title: string;
}
