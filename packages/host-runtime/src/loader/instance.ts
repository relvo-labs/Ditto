import type { Fiber } from '@deepseek-ai/cordis'
import type { CapabilityDefinition, CoreEvent, DittoMode, HealthReport, Json, RevokedGrant } from '../api.ts'
import type { HostEntrySpec } from './projection.ts'

/** A capability an instance registered. `leaseId` exists only after activation succeeded at Core. */
export interface Registration {
  instance: Instance
  definition: CapabilityDefinition
  leaseId?: string
  generation?: number
  /** Set while a register or revoke round-trip is in flight. */
  settling?: Promise<void>
  revoked: boolean
}

export interface Subscription {
  subscriptionId?: string
  topics: string[]
  handler: (event: CoreEvent) => void
}

export interface LifecycleHooks {
  health?: (signal: AbortSignal) => HealthReport | Promise<HealthReport>
  drain?: (signal: AbortSignal) => void | Promise<void>
  exportState?: () => Json | Promise<Json>
  importState?: (state: Json) => void | Promise<void>
}

/**
 * `candidate` instances live in an isolate realm during prepare (strategy A);
 * `main` instances live in the main realm. An instance is `mode: 'candidate'`
 * until the transaction layer activates it, whatever its realm.
 */
export type Realm = 'candidate' | 'main'

let sequence = 0

/** One mount of one entry. Every mount gets a fresh loader id, so a disposing mount never shares it. */
export class Instance {
  readonly loaderId: string
  mode: DittoMode = 'candidate'
  fiber?: Fiber
  /** The module's plugin export (the loader keeps only its apply function as the runtime key). */
  plugin?: { events?: unknown }
  mountedAt = 0
  /** Why this instance is not usable, in the vocabulary of `participant.*` reasons. */
  failure?: string
  hooks: LifecycleHooks = {}
  readonly registrations = new Map<string, Registration>()
  readonly subscriptions = new Set<Subscription>()
  readonly revokeHandlers = new Set<(grant: RevokedGrant) => void | Promise<void>>()
  disposal?: Promise<'done' | 'timeout'>
  /** Events a main-realm instance emitted before activation; sent on activation, dropped if it fails. */
  readonly heldEvents: { name: string; payload: Json; coalesce: 'none' | 'latest'; coalesceKey?: string }[] = []

  /** Replaced in place only by a volatile config commit or an unchanged `keep`. */
  constructor(public spec: HostEntrySpec, readonly realm: Realm, readonly changeId: string | null) {
    this.loaderId = `${realm === 'main' ? 'm' : 'c'}${++sequence}.${spec.entry_id}`
  }

  get entryId(): string { return this.spec.entry_id }
}
