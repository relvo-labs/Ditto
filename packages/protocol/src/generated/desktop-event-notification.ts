/* Generated from schema/desktop-event-notification.json; do not edit. */

export type DesktopEventPayload =
  | {
      type: 'window_upsert';
      window: Window;
      [k: string]: unknown;
    }
  | {
      type: 'window_removed';
      window_id: WindowSessionId;
      [k: string]: unknown;
    }
  | {
      type: 'workspace_upsert';
      workspace: Workspace;
      [k: string]: unknown;
    }
  | {
      type: 'workspace_removed';
      workspace_id: string;
      [k: string]: unknown;
    }
  | {
      output: Output;
      type: 'output_upsert';
      [k: string]: unknown;
    }
  | {
      output_name: string;
      type: 'output_removed';
      [k: string]: unknown;
    }
  | {
      reason: string;
      type: 'resync_required';
      [k: string]: unknown;
    };
/**
 * An opaque identifier valid only for the current compositor session.
 */
export type WindowSessionId = string;
export type WindowState = 'normal' | 'minimized' | 'maximized' | 'fullscreen';

export interface DesktopEventNotification {
  payload: DesktopEventPayload;
  /**
   * Observation revision; no persistent Profile exists in G0.
   */
  revision: number;
  seq: number;
  subscription_id: string;
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
export interface Output {
  enabled: boolean;
  height: number;
  name: string;
  scale: number;
  width: number;
  x: number;
  y: number;
}
