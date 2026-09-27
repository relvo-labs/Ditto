import type { Duplex } from 'node:stream'
import { RpcPeer } from '../bridge/rpc.ts'
import { protocolVersion } from '../bridge/core-link.ts'
import { DittoError } from '../errors.ts'
import type { HostEntrySpec } from '../loader/projection.ts'

/**
 * An in-memory stand-in for ditto-core on the hostd connection. It implements
 * the Core side of host-protocol.md closely enough for lifecycle tests: the
 * assigned-entry table behind `on_behalf_of`, candidate claims, single-provider
 * leases with TTL and generations, an authorisation table that fails closed,
 * and fault injection. It is not Core: no store, no ChangeSets, no readback.
 */

export type FaultAction =
  | { action: 'delay'; ms: number }
  | { action: 'timeout' }
  | { action: 'refuse'; error?: { name: string; message?: string; data?: Record<string, unknown> } }

interface Binding { leaseId: string; entryId: string; capabilityId: string; generation: number; expiresAt: number }
interface Assigned { state: 'candidate' | 'active'; provides: string[] }
interface Grant { capabilityId: string; resource?: string; revoked: boolean }

export interface HostEventRecord { entryId: string; name: string; payload: unknown; coalesceKey?: string; at: number }

export interface FakeCoreOptions {
  leaseTtlMs?: number
  heartbeatIntervalMs?: number
  generation?: number
  /** Capabilities that bind an exclusive resource; candidates calling them get `candidate_cannot_claim`. */
  claimable?: string[]
}

let leaseSequence = 0

export class FakeCore {
  readonly peer: RpcPeer
  readonly generation: number
  readonly leaseTtlMs: number
  readonly assigned = new Map<string, Assigned>()
  readonly bindings = new Map<string, Binding>()
  readonly hostEvents: HostEventRecord[] = []
  readonly entryStates: unknown[] = []
  readonly resources: unknown[] = []
  readonly heartbeats: number[] = []
  readonly requests: { method: string; params: Record<string, unknown> }[] = []
  readonly revokedLeases = new Set<string>()
  /** Core-served capabilities (e.g. `desktop.shortcuts.bind`) for plugins to call. */
  readonly services = new Map<string, (input: Record<string, unknown>, subject: string) => unknown>()
  readonly faults = new Map<string, FaultAction>()
  /** Answer a method with whatever a test needs (malformed replies, odd shapes). Checked after faults. */
  readonly overrides = new Map<string, (params: Record<string, unknown>) => unknown>()
  readonly subscriptions = new Map<string, { entryId: string; topics: string[] }>()
  private readonly grants = new Map<string, Grant[]>()
  private readonly claimable: Set<string>
  private committed = new Map<string, Assigned>()
  private pendingTable?: Map<string, Assigned>
  private subscriptionSequence = 0
  private seq = 0
  handshakes = 0
  closed = false

  constructor(stream: Duplex, options: FakeCoreOptions = {}) {
    this.generation = options.generation ?? 1
    this.leaseTtlMs = options.leaseTtlMs ?? 10_000
    this.heartbeatIntervalMs = options.heartbeatIntervalMs ?? 2_000
    this.claimable = new Set(options.claimable ?? ['desktop.shortcuts.bind', 'desktop.commands.bind'])
    this.peer = new RpcPeer(stream, 'core-', {
      request: (method, params) => this.onRequest(method, (params ?? {}) as Record<string, unknown>),
      notification: () => {},
      closed: () => { this.closed = true; this.dropConnection() },
    })
  }

  readonly heartbeatIntervalMs: number

  // ── driving hostd ───────────────────────────────────────────────────────

  prepare(changeId: string, entries: HostEntrySpec[], origin = 'changeset') {
    // New entries are assigned as candidates until commit (host-protocol §4.2).
    const table = new Map(this.committed)
    for (const entry of entries) if (!table.has(entry.entry_id)) table.set(entry.entry_id, { state: 'candidate', provides: entry.provides })
    this.pendingTable = new Map([...table].filter(([id]) => entries.some(entry => entry.entry_id === id) || this.committed.has(id)))
    this.syncAssigned()
    return this.peer.request<{ items: { key: string; status: string; reason?: string; missing?: string[] }[] }>(
      'participant.prepare', { change_id: changeId, origin, target: { role: 'hostd', entries } }, 15_000)
      .then(result => {
        this.lastTarget.set(changeId, entries)
        return result
      })
  }

  private readonly lastTarget = new Map<string, HostEntrySpec[]>()
  private readonly previousCommitted = new Map<string, Map<string, Assigned>>()

  async commit(changeId: string) {
    const entries = this.lastTarget.get(changeId) ?? []
    const previous = new Map(this.committed)
    this.previousCommitted.set(changeId, previous)
    // Core flips new entries to active when it sends commit, so hostd's held registrations are accepted.
    // Like ditto-core's Hosts::activate: entries absent from the target leave, with their leases, at once.
    this.committed = new Map(entries.map(entry => [entry.entry_id, { state: 'active', provides: entry.provides }]))
    this.pendingTable = undefined
    this.syncAssigned()
    this.dropUnassigned()
    try {
      return await this.peer.request<{ items: { key: string; status: string; reason?: string }[] }>('participant.commit', { change_id: changeId }, 30_000)
    } finally {
      this.pendingTable = undefined
      this.syncAssigned()
      this.dropUnassigned()
    }
  }

  async abort(changeId: string) {
    const result = await this.peer.request<Record<string, never>>('participant.abort', { change_id: changeId }, 30_000)
    this.pendingTable = undefined
    this.syncAssigned()
    this.dropUnassigned()
    return result
  }

  async rollback(changeId: string) {
    const previous = this.previousCommitted.get(changeId)
    const current = new Map(this.committed)
    if (previous) this.committed = new Map(previous)
    this.pendingTable = new Map([...current].filter(([id]) => !this.committed.has(id)))
    this.syncAssigned()
    try {
      return await this.peer.request<{ items: { key: string; status: string; reason?: string }[] }>('participant.rollback', { change_id: changeId }, 30_000)
    } finally {
      this.pendingTable = undefined
      this.syncAssigned()
      this.dropUnassigned()
    }
  }

  state(changeId?: string) {
    return this.peer.request<{ change: { change_id: string; phase: string } | null; observed: { entries: { entry_id: string; fiber_state: string; mode: string; waiting_for?: string[]; failure?: string }[] } }>(
      'participant.state', changeId ? { change_id: changeId } : {})
  }

  /** prepare + commit, or prepare + abort when any item failed. Mirrors Core's happy path. */
  async apply(changeId: string, entries: HostEntrySpec[]) {
    const prepared = await this.prepare(changeId, entries)
    if (prepared.items.some(item => item.status !== 'ready')) {
      await this.abort(changeId)
      return { prepared, committed: undefined }
    }
    const committed = await this.commit(changeId)
    return { prepared, committed }
  }

  /** Route a caller's request to the hostd provider through its lease, like Core's router. */
  async invoke(capabilityId: string, input: Record<string, unknown> = {}, caller = 'shell', deadlineMs = 2_000): Promise<unknown> {
    const binding = [...this.bindings.values()].find(item => item.capabilityId === capabilityId)
    if (!binding) throw new DittoError('unavailable', `${capabilityId} is not bound`, { reason: 'not_bound' })
    if (binding.expiresAt < Date.now()) throw new DittoError('unavailable', `${capabilityId} lease expired`, { reason: 'lease_expired' })
    return this.peer.request('host.invoke', {
      lease_id: binding.leaseId, entry_id: binding.entryId, capability_id: capabilityId,
      input, caller, operation_id: `op-${++this.seq}`, deadline_ms: deadlineMs,
    }, deadlineMs + 1_000)
  }

  /** Send host.invoke with an explicit (possibly stale) lease id — L-07 negative. */
  invokeWithLease(leaseId: string, entryId: string, capabilityId: string, input: Record<string, unknown> = {}) {
    return this.peer.request('host.invoke', { lease_id: leaseId, entry_id: entryId, capability_id: capabilityId, input, caller: 'shell', deadline_ms: 2_000 })
  }

  /** Allow `host:<entryId>` to call `capabilityId` (optionally on one resource) in `desktop.permissions.check`. */
  grant(entryId: string, capabilityId: string, resource?: string): void {
    const list = this.grants.get(entryId) ?? []
    list.push({ capabilityId, ...(resource !== undefined ? { resource } : {}), revoked: false })
    this.grants.set(entryId, list)
  }

  /** Revoke a grant the entry holds and tell hostd (host-protocol §9). File grants use scope `files:<grant>`. */
  revokeGrant(entryId: string, grantId: string, scope = `files:${grantId}`): void {
    for (const grant of this.grants.get(entryId) ?? []) if (grant.resource === grantId) grant.revoked = true
    this.peer.notify('host.permission_revoked', { entry_id: entryId, grant_id: grantId, scope })
  }

  /** Deliver a Core event on a subscription hostd opened. */
  publish(subscriptionId: string, event: Record<string, unknown>): void {
    this.peer.notify('desktop.events', { subscription_id: subscriptionId, seq: ++this.seq, ...event })
  }

  /** Expire every lease now, as if renewals had stopped for longer than the TTL. */
  expireLeases(): void {
    for (const binding of this.bindings.values()) binding.expiresAt = 0
  }

  bindingOf(capabilityId: string): Binding | undefined {
    return [...this.bindings.values()].find(item => item.capabilityId === capabilityId)
  }

  disconnect(): void { this.peer.close() }

  // ── Core side of the hostd connection ───────────────────────────────────

  private async onRequest(method: string, params: Record<string, unknown>): Promise<unknown> {
    this.requests.push({ method, params })
    const fault = this.faults.get(method)
    if (fault?.action === 'delay') await new Promise(resolve => setTimeout(resolve, fault.ms))
    if (fault?.action === 'timeout') return new Promise(() => {})
    if (fault?.action === 'refuse') {
      throw new DittoError((fault.error?.name ?? 'unavailable') as never, fault.error?.message ?? `${method} refused by fault injection`, fault.error?.data)
    }
    const override = this.overrides.get(method)
    if (override) return override(params)
    const meta = (params['_meta'] ?? {}) as Record<string, unknown>
    const onBehalfOf = typeof meta['on_behalf_of'] === 'string' ? meta['on_behalf_of'] : undefined
    switch (method) {
      case 'core.handshake': {
        this.handshakes += 1
        if (params['protocol_version'] !== protocolVersion) throw new DittoError('protocol_version_unsupported', 'only 0.2.0')
        return { protocol_version: protocolVersion, catalog_revision: 3, server: 'fake-core', compositor: 'none', mode: 'normal', subject: 'hostd', connection_id: 'conn-test', host_generation: this.generation }
      }
      case 'host.hello':
        return { host_generation: this.generation, mode: 'normal', heartbeat_interval_ms: this.heartbeatIntervalMs, lease_ttl_ms: this.leaseTtlMs }
      case 'host.heartbeat':
        this.heartbeats.push(Date.now())
        return {}
      case 'host.entry_state':
        this.entryStates.push(params['entries'])
        return {}
      case 'host.resources':
        this.resources.push(params)
        return {}
      case 'host.lease.renew': {
        const renewed: string[] = []
        const expired: string[] = []
        for (const leaseId of (params['lease_ids'] as string[]) ?? []) {
          const binding = this.bindings.get(leaseId)
          if (binding && binding.expiresAt >= Date.now()) {
            binding.expiresAt = Date.now() + this.leaseTtlMs
            renewed.push(leaseId)
          } else {
            if (binding) this.bindings.delete(leaseId)
            expired.push(leaseId)
          }
        }
        return { renewed, expired }
      }
    }
    const entry = this.requireEntry(onBehalfOf)
    switch (method) {
      case 'host.capability.register': {
        const capabilityId = String(params['capability_id'])
        if (entry.state === 'candidate') throw new DittoError('conflict', 'candidates cannot claim', { reason: 'candidate_cannot_claim' })
        if (!entry.provides.includes(capabilityId)) throw new DittoError('invalid_params', `${capabilityId} is not in provides`)
        this.dropExpired()
        const holder = this.bindingOf(capabilityId)
        if (holder) throw new DittoError('conflict', `${capabilityId} already bound`, { reason: 'single_provider_taken' })
        const leaseId = `lease-${++leaseSequence}`
        this.bindings.set(leaseId, { leaseId, entryId: onBehalfOf!, capabilityId, generation: this.generation, expiresAt: Date.now() + this.leaseTtlMs })
        return { lease_id: leaseId, ttl_ms: this.leaseTtlMs, generation: this.generation }
      }
      case 'host.capability.revoke': {
        const leaseId = String(params['lease_id'])
        const binding = this.bindings.get(leaseId)
        if (binding && binding.entryId !== onBehalfOf) throw new DittoError('identity_rejected', 'lease belongs to another entry')
        this.bindings.delete(leaseId)
        this.revokedLeases.add(leaseId)
        return {}
      }
      case 'host.event':
        this.hostEvents.push({ entryId: onBehalfOf!, name: String(params['name']), payload: params['payload'], ...(typeof params['coalesce_key'] === 'string' ? { coalesceKey: params['coalesce_key'] } : {}), at: Date.now() })
        return {}
      case 'desktop.permissions.check': {
        // Shape of ditto_protocol::services::PermissionsCheckOutput. Fail closed: a missing or
        // revoked grant needs approval, and with no approval responder that is a refusal.
        const capabilityId = String(params['capability_id'])
        const resource = typeof params['resource'] === 'string' ? params['resource'] : undefined
        const grant = this.grants.get(onBehalfOf!)?.find(item => item.capabilityId === capabilityId && item.resource === resource && !item.revoked)
        if (!grant) return { decision: 'needs_approval', effective: 'denied', reason: 'approval_unavailable', scopes: [] }
        return { decision: 'allowed', effective: 'allowed', reason: null, scopes: [] }
      }
      case 'desktop.events.subscribe': {
        const subscriptionId = `sub-${++this.subscriptionSequence}`
        this.subscriptions.set(subscriptionId, { entryId: onBehalfOf!, topics: (params['topics'] as string[]) ?? ['desktop'] })
        return { subscription_id: subscriptionId, seq: this.seq, snapshot: {} }
      }
    }
    if (this.claimable.has(method) && entry.state === 'candidate') {
      throw new DittoError('conflict', 'candidates cannot claim exclusive resources', { reason: 'candidate_cannot_claim' })
    }
    const service = this.services.get(method)
    if (!service) throw new DittoError('not_found', `fake Core has no ${method}`)
    const { _meta, ...input } = params
    return service(input, `host:${onBehalfOf}`)
  }

  private requireEntry(onBehalfOf: string | undefined): Assigned {
    const entry = onBehalfOf ? this.assigned.get(onBehalfOf) : undefined
    if (!entry) throw new DittoError('identity_rejected', `entry ${onBehalfOf ?? '(none)'} is not assigned to this hostd`)
    return entry
  }

  private syncAssigned(): void {
    this.assigned.clear()
    for (const [id, entry] of this.committed) this.assigned.set(id, entry)
    for (const [id, entry] of this.pendingTable ?? []) if (!this.assigned.has(id)) this.assigned.set(id, entry)
  }

  /** Bindings of entries no longer assigned are Core's to drop, whether or not hostd revoked them. */
  private dropUnassigned(): void {
    for (const [leaseId, binding] of this.bindings) if (!this.assigned.has(binding.entryId)) this.bindings.delete(leaseId)
  }

  private dropExpired(): void {
    for (const [leaseId, binding] of this.bindings) if (binding.expiresAt < Date.now()) this.bindings.delete(leaseId)
  }

  /** Connection lost: Core revokes every lease of that hostd at once (host-protocol §3). */
  private dropConnection(): void {
    this.bindings.clear()
    this.subscriptions.clear()
  }
}
