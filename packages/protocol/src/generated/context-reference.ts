/* Generated from schema/context-reference.json; do not edit. */

export type ContextKind = 'file' | 'clipboard' | 'capture';

/**
 * What a piece of context is, without its content. This is what a
 * conversation keeps; the content lives in Core's memory until released.
 */
export interface ContextReference {
  bytes: number;
  captured_at: string;
  context_id: string;
  expires_at_ms: number;
  kind: ContextKind;
  /**
   * A file name (never its path), "clipboard" or an output name.
   */
  label: string;
  mime: string;
  sha256: string;
  /**
   * The content was cut at the size limit.
   */
  truncated: boolean;
}
