/* Generated from schema/plugins-install-input.json; do not edit. */

export interface PluginsInstallInput {
  /**
   * When given, the package's sha256 must match (the lock a Profile or an
   * import expects).
   */
  expected_sha256?: string | null;
  idempotency_key: string;
  path: string;
}
