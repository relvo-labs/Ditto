/* Generated from schema/turn-complete-input.json; do not edit. */

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

export interface TurnCompleteInput {
  error_reason?: string | null;
  state: TurnState;
  turn_id: string;
}
