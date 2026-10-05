/* Generated from schema/request-meta.json; do not edit. */

export interface RequestMeta {
  deadline_ms?: number | null;
  /**
   * Only a hostd connection may, and must, name the entry it calls for.
   * Core accepts it only for an entry it assigned to that connection.
   */
  on_behalf_of?: string | null;
  operation_id?: string | null;
  protocol_version: string;
}
