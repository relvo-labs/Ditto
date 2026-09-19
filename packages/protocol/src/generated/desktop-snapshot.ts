/* Generated from schema/desktop-snapshot.json; do not edit. */

/**
 * An opaque identifier valid only for the current compositor session.
 */
export type WindowSessionId = string;
export type WindowState = 'normal' | 'minimized' | 'maximized' | 'fullscreen';

export interface DesktopSnapshot {
  outputs: Output[];
  windows: Window[];
  workspaces: Workspace[];
}
export interface Output {
  enabled: boolean;
  height: number;
  name: string;
  scale: number;
  width: number;
  x: number;
  y: number;
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
export interface Workspace {
  active: boolean;
  id: string;
  name: string;
}
