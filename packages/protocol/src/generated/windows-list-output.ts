/* Generated from schema/windows-list-output.json; do not edit. */

/**
 * An opaque identifier valid only for the current compositor session.
 */
export type WindowSessionId = string;
export type WindowState = 'normal' | 'minimized' | 'maximized' | 'fullscreen';

export interface WindowsListOutput {
  windows: Window[];
}
export interface Window {
  app_id: string;
  focused: boolean;
  height?: number | null;
  id: WindowSessionId;
  /**
   * The output the window is on, by the name `desktop.outputs.list`
   * reports. `x`/`y` are relative to that output (and to its current
   * workspace), not to the global layout, so a position is only meaningful
   * together with this name. Absent when the compositor does not say.
   */
  output?: string | null;
  state: WindowState;
  title: string;
  width?: number | null;
  workspace_id?: string | null;
  x?: number | null;
  y?: number | null;
}
