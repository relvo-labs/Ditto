/* Generated from schema/turn-stream-input.json; do not edit. */

export interface TurnStreamInput {
  /**
   * At most 4 KiB per call; the controller batches about every 50 ms.
   */
  text: string;
  turn_id: string;
}
