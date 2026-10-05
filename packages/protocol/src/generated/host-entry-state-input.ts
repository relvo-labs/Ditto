/* Generated from schema/host-entry-state-input.json; do not edit. */

export type FiberState = 'pending' | 'loading' | 'active' | 'unloading' | 'disposed' | 'failed';
export type EntryMode = 'candidate' | 'active';

export interface EntryStateInput {
  entries: EntryStateReport[];
}
export interface EntryStateReport {
  capabilities: number;
  effects: number;
  entry_id: string;
  failure?: string | null;
  fiber_state: FiberState;
  mode?: EntryMode | null;
  subscriptions: number;
  timers: number;
  waiting_for?: string[];
}
