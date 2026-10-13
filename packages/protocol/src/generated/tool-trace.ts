/* Generated from schema/tool-trace.json; do not edit. */

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
