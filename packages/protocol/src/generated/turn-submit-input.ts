/* Generated from schema/turn-submit-input.json; do not edit. */

export interface TurnSubmitInput {
  client_message_id: string;
  /**
   * Context the person attached to this message (`desktop.context.*`
   * ids). Attaching is the consent to send it to the model in this turn.
   */
  contexts?: string[];
  session_id: string;
  text: string;
}
