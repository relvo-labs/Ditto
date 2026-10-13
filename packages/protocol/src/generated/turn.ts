/* Generated from schema/turn.json; do not edit. */

export type TurnState =
  | 'queued'
  | 'running'
  | 'awaiting_approval'
  | 'cancelling'
  | 'succeeded'
  | 'failed'
  | 'partial'
  | 'unknown'
  | 'cancelled';

export interface Turn {
  created_at: string;
  error_reason?: string | null;
  operation_ids: string[];
  session_id: string;
  settings_revision: number;
  state: TurnState;
  tool_calls: number;
  turn_id: string;
}
