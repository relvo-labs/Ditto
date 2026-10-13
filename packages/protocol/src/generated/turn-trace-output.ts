/* Generated from schema/turn-trace-output.json; do not edit. */

export type ChangeState =
  | 'draft'
  | 'validated'
  | 'rejected'
  | 'prepared'
  | 'aborted'
  | 'applying'
  | 'verifying'
  | 'committed'
  | 'rolling_back'
  | 'rolled_back'
  | 'partially_applied'
  | 'unknown';
/**
 * What became of one tool call, as Core can prove it (G2-CORE-10).
 */
export type ToolOutcome = ('returned' | 'failed') | 'not_dispatched' | 'pending' | 'unknown';
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

/**
 * session → turn → tool → operation → ChangeSet → revision, read in one
 * snapshot: what a reconnecting client or a new Agent generation consults
 * instead of repeating anything.
 */
export interface TurnTraceOutput {
  tools: ToolTrace[];
  turn: Turn;
}
export interface ToolTrace {
  call_id: string;
  capability_id: string;
  /**
   * The ChangeSet the call produced, found by its operation id even when
   * the result was lost.
   */
  change_id?: string | null;
  change_state?: ChangeState | null;
  committed_revision?: string | null;
  /**
   * Also the `_meta.operation_id` the tool's request carried.
   */
  intent_id: string;
  outcome: ToolOutcome;
  /**
   * Boot recovery, not the live call, recorded this outcome.
   */
  recovered: boolean;
}
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
