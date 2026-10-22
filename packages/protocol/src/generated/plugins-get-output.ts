/* Generated from schema/plugins-get-output.json; do not edit. */

export type Coalesce = 'none' | 'latest';
export type HostKind = 'qml' | 'cordis' | 'core_builtin';
export type HotSwapLevel = 'instant' | 'controlled_handoff' | 'host_restart' | 'session_restart';
export type IdlePolicy = 'resident' | 'on_demand';
export type PluginKind = 'service' | 'qml_provider' | 'declarative_bundle';
export type TrustLevel = 'trusted' | 'community' | 'untrusted';

export interface PluginsGetOutput {
  manifest: Manifest;
  package: PackageSummary;
  /**
   * Every installed version of this package id.
   */
  versions: string[];
}
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
  settings_page?: SettingsPageDecl | null;
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
export interface SettingsPageDecl {
  category?: string | null;
  order: number;
  page_id: string;
  title_key: string;
}
export interface ShortcutDecl {
  chord: string;
  command: string;
}
export interface PackageSummary {
  author: string;
  host_kind: HostKind;
  installed_at: string;
  license: string;
  name: unknown;
  package_id: string;
  plugin_kind: PluginKind;
  /**
   * Retained revisions that pin this package; it cannot be removed while
   * any exists.
   */
  referenced_by: number;
  sha256: string;
  source: string;
  trust_level: TrustLevel;
  version: string;
}
