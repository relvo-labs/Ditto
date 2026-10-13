/* Generated from schema/tool-outcome.json; do not edit. */

/**
 * What became of one tool call, as Core can prove it (G2-CORE-10).
 */
export type ToolOutcome = ('returned' | 'failed') | 'not_dispatched' | 'pending' | 'unknown';
