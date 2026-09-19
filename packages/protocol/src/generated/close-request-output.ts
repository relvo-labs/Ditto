/* Generated from schema/close-request-output.json; do not edit. */

export interface CloseRequestOutput {
  /**
   * Accepted means the request reached the compositor. It does not mean the
   * application closed; observe a window event or read windows.list.
   */
  accepted: boolean;
  operation_id: string;
}
