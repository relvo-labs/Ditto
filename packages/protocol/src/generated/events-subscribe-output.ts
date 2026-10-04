/* Generated from schema/events-subscribe-output.json; do not edit. */

/**
 * An opaque identifier valid only for the current compositor session.
 */
export type WindowSessionId = string;
export type WindowState = 'normal' | 'minimized' | 'maximized' | 'fullscreen';

export interface EventsSubscribeOutput {
  /**
   * Set when the requested `after_seq` had already left the retained window:
   * the consumer must rebuild from this snapshot instead of continuing.
   */
  resynced?: boolean | null;
  seq: number;
  snapshot: DesktopSnapshot;
  subscription_id: string;
}
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
export interface Workspace {
  active: boolean;
  id: string;
  name: string;
}
