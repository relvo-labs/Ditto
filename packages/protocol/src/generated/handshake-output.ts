/* Generated from schema/handshake-output.json; do not edit. */

export interface HandshakeOutput {
  catalog_revision: number;
  /**
   * Which compositor Core is bound to, for measurement fingerprints.
   */
  compositor?: string | null;
  protocol_version: string;
  server: string;
}
