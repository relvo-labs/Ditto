/* Generated from schema/profiles-get-input.json; do not edit. */

export interface ProfilesGetInput {
  history_limit?: number | null;
  /**
   * Absent means the active Profile.
   */
  profile_id?: string | null;
  /**
   * Absent means the head revision.
   */
  revision_id?: string | null;
}
