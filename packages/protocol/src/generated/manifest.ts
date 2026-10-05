/* Generated from schema/manifest.json; do not edit. */

export type Coalesce = 'none' | 'latest';
export type HostKind = 'qml' | 'cordis' | 'core_builtin';
export type HotSwapLevel = 'instant' | 'controlled_handoff' | 'host_restart' | 'session_restart';
export type IdlePolicy = 'resident' | 'on_demand';
export type PluginKind = 'service' | 'qml_provider' | 'declarative_bundle';
export type TrustLevel = 'trusted' | 'community' | 'untrusted';

export interface Manifest {
  activation_events?: string[];
  author: string;
  cleanup: TimeoutDecl;
  commands?: CommandDecl[];
  config_schema?: {
    [k: string]: unknown;
  };
  conflicts?: string[];
  data_schema?: unknown;
  description?: unknown;
  entry?: string | null;
  events?: EventDecl[];
  health: TimeoutDecl;
  host_kind: HostKind;
  hot_swap: HotSwapLevel;
  id: string;
  idle_policy: IdlePolicy;
  license: string;
  manifest_version: number;
  migrations?: unknown[];
  /**
   * A string, or a `{ locale: text }` object.
   */
  name: {
    [k: string]: unknown;
  };
  optional?: Item[];
  permissions?: string[];
  platform?: string[];
  plugin_kind: PluginKind;
  provides?: Item[];
  qml_entry?: string | null;
  required_protocol_version: string;
  requires?: Item[];
  rescue?: RescueDecl;
  resource_budget?: ResourceBudget;
  runtime?: RuntimeRequirement;
  shortcuts?: ShortcutDecl[];
  slots?: string[];
  source: string;
  trust_level: TrustLevel;
  version: string;
}
export interface TimeoutDecl {
  timeout_ms: number;
}
export interface CommandDecl {
  id: string;
  title_key: string;
}
export interface EventDecl {
  coalesce: Coalesce;
  name: string;
  schema: unknown;
}
/**
 * What a package provides or depends on. Exactly one field is set.
 */
export interface Item {
  capability?: string | null;
  package?: string | null;
  service?: string | null;
  /**
   * semver range, for `package` dependencies.
   */
  version?: string | null;
}
export interface RescueDecl {
  disable_safe?: boolean;
}
export interface ResourceBudget {
  cpu_percent?: number | null;
  memory_mib?: number | null;
}
export interface RuntimeRequirement {
  node?: string | null;
  qt?: string | null;
}
export interface ShortcutDecl {
  chord: string;
  command: string;
}
