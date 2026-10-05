/* Generated from schema/appearance-set-input.json; do not edit. */

/**
 * Every field optional; the ones given become `set_value` ops of one
 * ChangeSet, so this has preflight, readback and history like any change.
 */
export interface AppearanceSetInput {
  base_revision: string;
  idempotency_key?: string | null;
  locale?: string | null;
  low_power_style?: boolean | null;
  reduced_motion?: boolean | null;
  reduced_transparency?: boolean | null;
  theme?: string | null;
  tokens?: {
    [k: string]: string;
  } | null;
}
