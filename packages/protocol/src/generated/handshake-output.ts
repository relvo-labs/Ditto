/* Generated from schema/handshake-output.json; do not edit. */

export type CoreMode = 'normal' | 'rescue';

export interface HandshakeOutput {
  catalog_revision: number;
  /**
   * Which compositor Core is bound to, for measurement fingerprints.
   */
  compositor?: string | null;
  connection_id: string;
  /**
   * Set for a hostd connection: increases with every new connection, so a
   * lease from an earlier generation can be told apart and refused.
   */
  host_generation?: number | null;
  mode: CoreMode;
  protocol_version: string;
  server: string;
  /**
   * The authorization subject this connection was bound to.
   */
  subject: string;
}
