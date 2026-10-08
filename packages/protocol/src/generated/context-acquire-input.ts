/* Generated from schema/context-acquire-input.json; do not edit. */

export type ContextKind = 'file' | 'clipboard' | 'capture';

export interface ContextAcquireInput {
  kind: ContextKind;
  /**
   * `capture`: the output to capture; absent means the primary one.
   */
  output?: string | null;
  /**
   * `file`: a path under the person's home directory.
   */
  path?: string | null;
}
