/**
 * The `ctx.ditto` surface plugins see. Everything here is a Ditto bridge over
 * protocol 0.2; none of it is a Cordis feature (milestones/01/02 §2.2, §2.4).
 */
import type { StandardSchemaV1 } from '@standard-schema/spec'
import type {} from '@deepseek-ai/cordis'

export type Json = null | boolean | number | string | Json[] | { [key: string]: Json }

export type DittoMode = 'candidate' | 'active'

export interface InvocationContext {
  /** Subject Core authorised, e.g. `shell`, `cli`, `host:<entry_id>`. Informational only. */
  caller: string
  operationId?: string
  deadlineMs: number
  /** Aborted when the deadline passes or the instance starts unloading. */
  signal: AbortSignal
}

export interface CapabilityDefinition<I = any, O = any> {
  /** `desktop.*` from the static catalog, or `plugin.<package>.*` declared in the manifest. */
  id: string
  version: string
  /** Optional input validation; the cross-process contract is still the manifest and Core's catalog. */
  input?: StandardSchemaV1<unknown, I>
  handler: (input: I, call: InvocationContext) => O | Promise<O>
}

export interface EmitOptions {
  /** Overrides the declared policy. `latest` merges queued events that share `coalesceKey`. */
  coalesce?: 'none' | 'latest'
  coalesceKey?: string
}

export interface CoreEvent {
  subscription_id: string
  seq: number
  [key: string]: unknown
}

export interface PermissionDecision {
  /** What a call would actually get (Core's `effective`); `needs_approval` is a denial in G1. */
  decision: 'allowed' | 'denied'
  /** Present when denied, e.g. `not_granted`, `policy_denied`, `approval_unavailable`. */
  reason?: string
}

export interface RevokedGrant {
  entry_id: string
  grant_id: string
  scope: string
}

/** A `files:<grant>` grant Core pushed with this entry. Only this one path is reachable through it. */
export interface GrantedFile {
  grantId: string
  path: string
  readText(): Promise<string>
  /** Atomic replace (temporary file in the same directory, then rename). */
  writeText(text: string): Promise<void>
}

/** Plugin data area under the `data_dir` Core assigned. Paths are relative and cannot escape it. */
export interface DataArea {
  readonly dir: string
  readText(path: string): Promise<string | undefined>
  writeText(path: string, text: string): Promise<void>
  readJson<T = Json>(path: string): Promise<T | undefined>
  writeJson(path: string, value: Json): Promise<void>
  remove(path: string): Promise<void>
  list(path?: string): Promise<string[]>
}

export interface HealthReport {
  healthy: boolean
  detail?: string
}

export interface Lifecycle {
  /** Replaces the default check ("fiber ACTIVE and apply did not throw"). Timeout from the manifest (default 2 s). */
  health(check: (signal: AbortSignal) => HealthReport | Promise<HealthReport>): () => void
  /** Stop taking new work and finish in-flight work. Bounded at 3 s, then the signal aborts. */
  onDrain(drain: (signal: AbortSignal) => void | Promise<void>): () => void
  /** Data only (≤1 MiB serialised). Contexts, closures and objects never cross to the new instance. */
  exportState(exporter: () => Json | Promise<Json>): () => void
  importState(importer: (state: Json) => void | Promise<void>): () => void
}

export interface DittoApi {
  /** Core-generated entry id this instance serves. */
  readonly entryId: string
  /** `candidate` until the transaction layer activates the instance; candidates hold no leases. */
  readonly mode: DittoMode
  readonly capabilities: {
    /** An effect: disposing the plugin revokes the lease. In candidate mode it is only recorded. */
    register<I, O>(definition: CapabilityDefinition<I, O>): () => Promise<void>
    /** Call another capability as `host:<entry_id>`. Authorisation happens in Core. */
    call<T = unknown>(capabilityId: string, input?: Record<string, unknown>): Promise<T>
  }
  readonly events: {
    /** Cross-process event; must be declared in the manifest `events`. Dropped while a candidate. */
    emit(name: string, payload: Json, options?: EmitOptions): void
    /** Subscribe to Core topics (`desktop.events.subscribe`). An effect. */
    subscribe(topics: string[], handler: (event: CoreEvent) => void): () => void
  }
  readonly data: DataArea
  readonly permissions: {
    /** Would a call to `capabilityId` (on `resource`) be allowed for this entry? Asks Core; never defaults to allow. */
    check(capabilityId: string, resource?: string): Promise<PermissionDecision>
    /** The file behind a `files:<grant>` grant, from the entry's projection. Rejects if the grant is absent or revoked. */
    resolveFile(grantId: string): Promise<GrantedFile>
    /** An effect; plugins must stop using the grant (plan/03/02 §8.4 gives them 5 s). */
    onRevoked(handler: (grant: RevokedGrant) => void | Promise<void>): () => void
  }
  readonly lifecycle: Lifecycle
}

declare module '@deepseek-ai/cordis' {
  interface Context {
    ditto: DittoApi
  }
}
