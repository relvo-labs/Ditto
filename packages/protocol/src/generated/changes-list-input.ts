/* Generated from schema/changes-list-input.json; do not edit. */

export interface ChangesListInput {
  /**
   * Only changes created before this change id.
   */
  before?: string | null;
  limit?: number | null;
  profile_id?: string | null;
}
