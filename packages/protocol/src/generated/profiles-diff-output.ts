/* Generated from schema/profiles-diff-output.json; do not edit. */

export type DiffKind = 'added' | 'removed' | 'changed';

export interface ProfilesDiffOutput {
  from_revision: string;
  items: DiffItem[];
  to_revision: string;
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
