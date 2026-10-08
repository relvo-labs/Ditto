/* Generated from schema/changes-propose-input.json; do not edit. */

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

export interface ChangesProposeInput {
  base_revision: string;
  idempotency_key?: string | null;
  mode?: 'apply' | 'preview';
  ops: ChangeOp[];
  profile_id?: string | null;
  surface?: string | null;
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
