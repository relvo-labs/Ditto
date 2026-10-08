/* Generated from schema/tool-abandon-input.json; do not edit. */

export type ToolAbandonReason = 'permission_denied' | 'cancelled';

export interface ToolAbandonInput {
  intent_id: string;
  reason: ToolAbandonReason;
}
