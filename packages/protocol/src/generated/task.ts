/* Generated from schema/task.json; do not edit. */

export interface Task {
  done: boolean;
  priority?: string | null;
  /**
   * `own` (the plugin's list) or `file:<grant_id>`.
   */
  source: string;
  task_id: string;
  text: string;
}
