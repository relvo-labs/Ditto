/* Generated from schema/launcher-launch-output.json; do not edit. */

/**
 * Starting a program is observable; a window appearing is not guaranteed,
 * so this never claims success: confirm with `desktop.windows.list`.
 */
export interface LauncherLaunchOutput {
  accepted: boolean;
  app_id: string;
  operation_id: string;
  unit: string;
}
