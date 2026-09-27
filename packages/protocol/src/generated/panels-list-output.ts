/* Generated from schema/panels-list-output.json; do not edit. */

export interface PanelsListOutput {
  panels: PanelStatus[];
  reported_at?: string | null;
  shell_connected: boolean;
}
export interface PanelStatus {
  bound_entry?: string | null;
  mounted: boolean;
  mounted_entry?: string | null;
  package?: string | null;
  slot: string;
  visible: boolean;
}
