/* Generated from schema/tasks-subscribe-output.json; do not edit. */

export interface TasksSubscribeOutput {
  seq: number;
  snapshot: TasksListOutput;
  subscription_id: string;
}
export interface TasksListOutput {
  /**
   * Sample content is labelled, never presented as the user's own.
   */
  demo: boolean;
  sources: TaskSource[];
  tasks: Task[];
}
export interface TaskSource {
  source: string;
  /**
   * `ok`, `revoked`, `unavailable`.
   */
  status: string;
}
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
