/* Generated from schema/profiles-import-validate-output.json; do not edit. */

export type ImportProblemKind =
  | 'schema_invalid'
  | 'format_unsupported'
  | 'protocol_incompatible'
  | 'digest_mismatch'
  | 'package_missing'
  | 'integrity_mismatch'
  | 'grant_required'
  | 'secret_detected'
  | 'private_path_detected';

export interface ProfilesImportValidateOutput {
  importable: boolean;
  problems: ImportProblem[];
}
export interface ImportProblem {
  /**
   * Blocking problems stop the import; the others are shown and kept.
   */
  blocking: boolean;
  detail?: {
    [k: string]: unknown;
  };
  detail_key: string;
  kind: ImportProblemKind;
}
