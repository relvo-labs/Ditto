/* Generated from schema/participant-step-report.json; do not edit. */

export type ItemStatus = ('ready' | 'failed' | 'applied' | 'restored' | 'not_restored') | 'pending';

export interface StepReport {
  items: ItemReport[];
}
export interface ItemReport {
  /**
   * A slot name, an entry id, or `appearance`/`avatar`/`layout`/`shortcuts`.
   */
  key: string;
  missing?: string[];
  reason?: string | null;
  status: ItemStatus;
}
