/* Generated from schema/plugins-diagnostics-output.json; do not edit. */

export type FiberState = 'pending' | 'loading' | 'active' | 'unloading' | 'disposed' | 'failed';
export type HostKind = 'qml' | 'cordis' | 'core_builtin';

export interface PluginsDiagnosticsOutput {
  core: CoreCounts;
  entries: EntryDiagnostics[];
  host: HostStatus;
}
export interface CoreCounts {
  capability_bindings: number;
  leases: number;
  shell_mounted_providers: number;
  subscriptions: number;
}
export interface EntryDiagnostics {
  dependencies: string[];
  entry_id: string;
  fiber_state?: FiberState | null;
  host: HostKind;
  last_health?: string | null;
  last_rollback?: string | null;
  package: string;
  providers: {
    [k: string]: string;
  };
  registrations: RegistrationCounts;
  /**
   * Always set for hostd entries: in-process plugins share one host and
   * have no memory figure of their own (RUN-08).
   */
  shared_host_note_key?: string | null;
  supervisor_note?: string | null;
  version: string;
  waiting_for: string[];
}
export interface RegistrationCounts {
  capabilities: number;
  effects: number;
  leases: number;
  subscriptions: number;
  timers: number;
}
export interface HostStatus {
  generation?: number | null;
  heap?: NodeHeap | null;
  process?: ProcessResources | null;
  restarts_last_10_min: number;
  /**
   * `running`, `starting`, `stopped`, `crash_loop`, `not_needed`, `rescue_mode`.
   */
  state: string;
  strategy?: string | null;
  versions: {
    [k: string]: string;
  };
}
export interface NodeHeap {
  array_buffers: number;
  external: number;
  heap_used: number;
}
/**
 * Process-level figures Core read from `/proc`; hostd's own report is only
 * used for the Node heap, listed separately and never added to these.
 */
export interface ProcessResources {
  cpu_ticks?: number | null;
  fds?: number | null;
  pid: number;
  pss_kib?: number | null;
  rss_kib?: number | null;
  threads?: number | null;
}
