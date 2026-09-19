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
  state: WindowState;
  title: string;
  width?: number | null;
  workspace_id?: string | null;
  x?: number | null;
  y?: number | null;
}
