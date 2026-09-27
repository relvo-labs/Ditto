/* Generated from schema/launcher-apps-output.json; do not edit. */

export interface LauncherAppsOutput {
  apps: AppEntry[];
  /**
   * The index is a rebuildable cache, not configuration.
   */
  indexed_at?: string | null;
}
export interface AppEntry {
  app_id: string;
  categories: string[];
  generic_name?: string | null;
  icon?: string | null;
  keywords: string[];
  name: string;
}
