/* Generated from schema/change-record.json; do not edit. */

export type DiffKind = 'added' | 'removed' | 'changed';
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
    }
  | {
      at: string;
      reason: ConfirmationEndReason;
      state: 'ended';
      [k: string]: unknown;
    };
export type ConfirmationEndReason = 'profile_deleted';
export type HotSwapLevel = 'instant' | 'controlled_handoff' | 'host_restart' | 'session_restart';
export type OutcomeStatus = ('applied' | 'failed' | 'restored' | 'not_restored' | 'pending') | 'scheduled';
/**
 * `before` fields are intent: Core refills them from the base revision and
 * refuses the change when a caller-supplied value disagrees, because the
 * caller planned against a state that no longer exists.
 */
export type ChangeOp =
  | {
      after: unknown;
      before?: unknown;
      op: 'set_value';
      /**
       * JSON pointer into the document, limited to `/appearance`, `/avatar`,
       * `/layout` and `/shortcuts`.
       */
      path: string;
    }
  | {
      entry: NewEntry;
      op: 'add_entry';
      slot?: string | null;
    }
  | {
      entry_id: string;
      op: 'remove_entry';
    }
  | {
      /**
       * The whole new config. Preflight accepts only an object, and the
       * schema says so, so a model is not left to guess (a JSON-encoded
       * string is rejected, never parsed).
       */
      after: {
        [k: string]: unknown;
      };
      before?: unknown;
      entry_id: string;
      op: 'set_entry_config';
    }
  | {
      disabled: boolean;
      entry_id: string;
      op: 'set_entry_disabled';
    }
  | {
      entry_id: string;
      from_version: string;
      op: 'upgrade_entry';
      to_version: string;
    }
  | {
      from?: string | null;
      op: 'bind_slot';
      slot: string;
      to: string;
    }
  | {
      op: 'switch_profile';
      to_profile: string;
      to_revision?: string | null;
    };
export type HostKind = 'qml' | 'cordis' | 'core_builtin';
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
export type PreflightCode =
  | 'base_revision_stale'
  | 'schema_invalid'
  | 'stale_intent'
  | 'package_missing'
  | 'integrity_mismatch'
  | 'protocol_incompatible'
  | 'dependency_missing'
  | 'dependency_cycle'
  | 'version_conflict'
  | 'declared_conflict'
  | 'single_provider_violation'
  | 'shortcut_conflict'
  | 'command_conflict'
  | 'permission_required'
  | 'precondition_failed'
  | 'budget_exceeded';
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

export interface ChangeRecord {
  base_revision: string;
  card: ChangeCard;
  change_id: string;
  /**
   * The revision this change produced, once committed.
   */
  committed_revision?: string | null;
  confirmation: Confirmation;
  created_at: string;
  failure_key?: string | null;
  hot_swap_level: HotSwapLevel;
  idempotency_key?: string | null;
  /**
   * Per-op outcomes as read back.
   */
  items?: OutcomeItem[];
  operations?: OperationSummary[];
  ops: ChangeOp[];
  origin: ChangeOrigin;
  /**
   * The change's Profile has been deleted since (#171), read when the
   * record is read (the delete is soft; the record stays). The Profile
   * cannot be switched to any more, so nothing of it applies again, and
   * undo is refused (protocol 0.2 §8.6). Left out while false.
   */
  profile_deleted?: boolean;
  profile_id: string;
  /**
   * Every preflight failure, when rejected.
   */
  reasons?: PreflightReason[];
  /**
   * Set when boot recovery decided this change's outcome.
   */
  recovered_at?: string | null;
  result?: ResultKind | null;
  /**
   * Present only when the change was committed without anything being
   * applied to the desktop because its Profile was not active (#169).
   * Absent on every other record and on every record written before
   * store schema 6; absence alone does not mean the change was applied,
   * `state` and `result` still say what happened.
   */
  saved_only?: SavedOnly | null;
  state: ChangeState;
  updated_at: string;
}
/**
 * The change card: prototype contract (kind, title, items, footnote), with
 * translation keys instead of text.
 */
export interface ChangeCard {
  footnote_key?: string | null;
  items: DiffItem[];
  kind: string;
  title_args?: {
    [k: string]: unknown;
  };
  title_key: string;
}
/**
 * One line of a change card. The label is a translation key so Core never
 * emits locale-specific text; the Shell renders it in the Profile's language.
 */
export interface DiffItem {
  after?: unknown;
  before?: unknown;
  kind: DiffKind;
  label_args?: {
    [k: string]: unknown;
  };
  label_key: string;
  path: string;
}
/**
 * What happened to one op, as read back. A partial result lists every item.
 */
export interface OutcomeItem {
  key: string;
  op_index: number;
  participant: string;
  reason?: string | null;
  status: OutcomeStatus;
}
export interface OperationSummary {
  ended_at?: string | null;
  operation_id: string;
  participant: string;
  seq: number;
  started_at: string;
  state: string;
  step: string;
}
export interface NewEntry {
  config?: {
    [k: string]: unknown;
  };
  disabled?: boolean;
  host: HostKind;
  package: string;
  version: string;
}
export interface PreflightReason {
  code: PreflightCode;
  detail?: {
    [k: string]: unknown;
  };
  detail_key: string;
  op_index?: number | null;
}
/**
 * A committed change that wrote its Profile's revision and applied nothing
 * to the desktop (protocol 0.2 §8.1). `result` stays `succeeded`: the edit
 * of the stored Profile is done; this says where it went.
 */
export interface SavedOnly {
  /**
   * The Profile's name when the record is read (it can be renamed since).
   */
  profile_name: string;
  reason: SavedOnlyReason;
}
