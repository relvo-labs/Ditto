/* Generated from schema/change-summary.json; do not edit. */

export type Confirmation =
  | {
      state: 'not_required';
      [k: string]: unknown;
    }
  | {
      deadline: string;
      state: 'pending';
      [k: string]: unknown;
    }
  | {
      at: string;
      state: 'confirmed';
      [k: string]: unknown;
    }
  | {
      by_change: string;
      state: 'reverted';
      [k: string]: unknown;
    };
export type HotSwapLevel = 'instant' | 'controlled_handoff' | 'host_restart' | 'session_restart';
export type ChangeOrigin =
  | {
      kind: 'gui';
      surface?: string | null;
      [k: string]: unknown;
    }
  | {
      kind: 'cli';
      [k: string]: unknown;
    }
  | {
      kind: 'agent_standin';
      [k: string]: unknown;
    }
  | {
      kind: 'agent';
      session_id: string;
      tool_call_id: string;
      turn_id: string;
      [k: string]: unknown;
    }
  | {
      kind: 'rescue';
      [k: string]: unknown;
    }
  | {
      kind: 'supervisor';
      reason: string;
      [k: string]: unknown;
    }
  | {
      kind: 'timed_revert';
      reverts: string;
      [k: string]: unknown;
    }
  | {
      kind: 'undo';
      undoes: string;
      [k: string]: unknown;
    }
  | {
      kind: 'import';
      [k: string]: unknown;
    };
export type ResultKind = ('succeeded' | 'failed' | 'partial' | 'unknown') | 'scheduled';
export type SavedOnlyReason = 'inactive_profile';
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

export interface ChangeSummary {
  change_id: string;
  committed_revision?: string | null;
  confirmation: Confirmation;
  created_at: string;
  hot_swap_level: HotSwapLevel;
  origin: ChangeOrigin;
  profile_id: string;
  result?: ResultKind | null;
  /**
   * As on [`ChangeRecord::saved_only`].
   */
  saved_only?: SavedOnly | null;
  state: ChangeState;
  title_key: string;
  updated_at: string;
}
/**
 * A committed change that wrote its Profile's revision and applied nothing
 * to the desktop (protocol 0.2 §8.1). `result` stays `succeeded`: the edit
 * of the stored Profile is done; this says where it went.
 */
export interface SavedOnly {
  /**
   * The Profile has been deleted since (#171), read with the name. It
   * can no longer be switched to, so the change will never apply, and
   * undo is refused (protocol 0.2 §8.6). Left out while false.
   */
  profile_deleted?: boolean;
  /**
   * The Profile's name when the record is read (it can be renamed since).
   */
  profile_name: string;
  reason: SavedOnlyReason;
}
