/* Generated from schema/profiles-create-input.json; do not edit. */

export type ProfileTemplate = 'default' | 'empty';

export interface ProfilesCreateInput {
  from: ProfileTemplate;
  idempotency_key?: string | null;
  name: string;
}
