/* Generated from schema/generated-description.json; do not edit. */

export type Content =
  | {
      max_items: number;
      order: TaskOrder;
      show_completed: boolean;
      template: 'tasks_summary_v1';
    }
  | {
      /**
       * @minItems 1
       * @maxItems 16
       */
      actions:
        | [WorkspaceAction]
        | [WorkspaceAction, WorkspaceAction]
        | [WorkspaceAction, WorkspaceAction, WorkspaceAction]
        | [WorkspaceAction, WorkspaceAction, WorkspaceAction, WorkspaceAction]
        | [WorkspaceAction, WorkspaceAction, WorkspaceAction, WorkspaceAction, WorkspaceAction]
        | [WorkspaceAction, WorkspaceAction, WorkspaceAction, WorkspaceAction, WorkspaceAction, WorkspaceAction]
        | [
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction
          ]
        | [
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction
          ]
        | [
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction
          ]
        | [
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction
          ]
        | [
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction
          ]
        | [
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction
          ]
        | [
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction
          ]
        | [
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction
          ]
        | [
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction
          ]
        | [
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction,
            WorkspaceAction
          ];
      template: 'workspace_actions_v1';
    };
export type TaskOrder = 'source' | 'title';
export type DataType = 'text' | 'integer' | 'boolean' | 'text_list';
export type RollbackPolicy = 'snapshot' | 'compatible' | 'unavailable';

export interface Description {
  accent: string;
  content: Content;
  data?: DataPlan;
  format_version: number;
  plugin_id: string;
  title: string;
  version: string;
  width: number;
}
export interface WorkspaceAction {
  label: string;
  workspace_id: string;
}
export interface DataPlan {
  fields?: {
    [k: string]: DataType;
  };
  migration?: DataMigration | null;
  schema_version: number;
}
export interface DataMigration {
  defaults?: {
    [k: string]: unknown;
  };
  from_version: number;
  remove?: string[];
  rename?: {
    [k: string]: string;
  };
  rollback: RollbackPolicy;
}
