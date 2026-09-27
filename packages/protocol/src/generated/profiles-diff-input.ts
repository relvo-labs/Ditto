/* Generated from schema/profiles-diff-input.json; do not edit. */

export interface ProfilesDiffInput {
  from: RevisionRef;
  to: RevisionRef;
}
/**
 * Either a revision, or the head of a Profile.
 */
export interface RevisionRef {
  profile_id?: string | null;
  revision_id?: string | null;
}
