/* Generated from schema/context-preview-output.json; do not edit. */

export type ContextKind = 'file' | 'clipboard' | 'capture';

export interface ContextPreviewOutput {
  /**
   * Image size, for captures.
   *
   * @minItems 2
   * @maxItems 2
   */
  image_size?: [number, number] | null;
  reference: ContextReference;
  /**
   * The beginning of text content, for the person to check.
   */
  text?: string | null;
}
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
