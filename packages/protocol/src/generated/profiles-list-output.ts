/* Generated from schema/profiles-list-output.json; do not edit. */

export interface ProfilesListOutput {
  active_profile?: string | null;
  profiles: ProfileSummary[];
}
export interface ProfileSummary {
  active: boolean;
  created_at: string;
  head_revision: string;
  last_known_good?: string | null;
  name: string;
  profile_id: string;
  updated_at: string;
}
