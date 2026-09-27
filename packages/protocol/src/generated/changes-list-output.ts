/* Generated from schema/changes-list-output.json; do not edit. */

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

export interface ChangesListOutput {
  changes: ChangeSummary[];
}
export interface ChangeSummary {
  change_id: string;
  committed_revision?: string | null;
  confirmation: Confirmation;
  created_at: string;
  hot_swap_level: HotSwapLevel;
  origin: ChangeOrigin;
  profile_id: string;
  result?: ResultKind | null;
  state: ChangeState;
  title_key: string;
  updated_at: string;
}
