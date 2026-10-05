/* Generated from schema/shortcuts-list-output.json; do not edit. */

export interface ShortcutsListOutput {
  /**
   * How shortcuts reach the compositor on this platform (C-16).
   */
  binding_path: string;
  shortcuts: ShortcutInfo[];
}
export interface ShortcutInfo {
  bound: boolean;
  chord: string;
  command: string;
  conflict: boolean;
  owner: string;
  /**
   * Kept by Core (rescue, lock); a plugin may not declare these.
   */
  reserved: boolean;
}
