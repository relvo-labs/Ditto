/* Generated from schema/plugins-list-output.json; do not edit. */

export type HostKind = 'qml' | 'cordis' | 'core_builtin';
export type EntryRuntimeState =
  | {
      kind: 'active';
      [k: string]: unknown;
    }
  | {
      kind: 'pending';
      waiting_for: string[];
      [k: string]: unknown;
    }
  | {
      kind: 'loading';
      [k: string]: unknown;
    }
  | {
      kind: 'failed';
      reason: string;
      [k: string]: unknown;
    }
  | {
      kind: 'disabled';
      [k: string]: unknown;
    }
  | {
      at: string;
      kind: 'supervisor_disabled';
      reason: string;
      [k: string]: unknown;
    }
  | {
      kind: 'unavailable';
      reason: UnavailableReason;
      [k: string]: unknown;
    }
  | {
      kind: 'not_reported';
      [k: string]: unknown;
    };
/**
 * Why a capability or a call is unavailable. Closed: a consumer can show a
 * specific product sentence for every value.
 */
export type UnavailableReason =
  | (
      | 'compositor_offline'
      | 'host_unavailable'
      | 'host_crash_loop'
      | 'lease_expired'
      | 'not_bound'
      | 'rescue_mode'
      | 'recovering'
      | 'system_unavailable'
      | 'participant_unavailable'
      | 'session_locked'
    )
  | 'storage_full'
  | 'storage_error';
export type PluginKind = 'service' | 'qml_provider' | 'declarative_bundle';
export type TrustLevel = 'trusted' | 'community' | 'untrusted';

export interface PluginsListOutput {
  entries: EntryStatus[];
  packages: PackageSummary[];
}
export interface EntryStatus {
  disabled: boolean;
  entry_id: string;
  host: HostKind;
  package: string;
  slot?: string | null;
  /**
   * Why it runs: `profile` (enabled in the active Profile).
   */
  started_reason: string;
  state: EntryRuntimeState;
  trust_note_key: string;
  version: string;
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
