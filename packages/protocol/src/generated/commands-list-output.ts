/* Generated from schema/commands-list-output.json; do not edit. */

export interface CommandsListOutput {
  commands: CommandInfo[];
}
export interface CommandInfo {
  command_id: string;
  /**
   * `core`, `shell`, or an entry id.
   */
  owner: string;
  title_key: string;
}
