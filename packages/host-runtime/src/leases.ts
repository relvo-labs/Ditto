import type { CoreChannel } from './bridge/core-link.ts'
import { describe } from './errors.ts'
import type { Registration } from './loader/instance.ts'
import type { HostLog } from './log.ts'

interface RegisterResult { lease_id: string; ttl_ms: number; generation: number }
interface RenewResult { renewed: string[]; expired: string[] }

/**
 * Leases on capability bindings (host-protocol §5). Core owns the binding;
 * hostd only holds lease ids and renews them in one batch. A lease id is never
 * reused: after expiry the capability is registered again and gets a new one.
 */
export class LeaseTable {
  private readonly byLease = new Map<string, Registration>()

  constructor(private readonly core: CoreChannel, private readonly log: HostLog) {}

  get size(): number { return this.byLease.size }
  lookup(leaseId: string): Registration | undefined { return this.byLease.get(leaseId) }
  ids(): string[] { return [...this.byLease.keys()] }

  async register(registration: Registration): Promise<void> {
    const { instance, definition } = registration
    const result = await this.core.request<RegisterResult>('host.capability.register', {
      capability_id: definition.id,
      version: definition.version,
    }, { onBehalfOf: instance.entryId })
    if (registration.revoked) {
      // The plugin unloaded while the request was in flight; give the lease straight back.
      await this.core.request('host.capability.revoke', { lease_id: result.lease_id }, { onBehalfOf: instance.entryId }).catch(() => {})
      return
    }
    registration.leaseId = result.lease_id
    registration.generation = result.generation
    this.byLease.set(result.lease_id, registration)
  }

  async revoke(registration: Registration): Promise<void> {
    registration.revoked = true
    await registration.settling?.catch(() => {})
    const leaseId = registration.leaseId
    if (!leaseId) return
    this.byLease.delete(leaseId)
    registration.leaseId = undefined
    try {
      await this.core.request('host.capability.revoke', { lease_id: leaseId }, { onBehalfOf: registration.instance.entryId })
    } catch (error) {
      // Core revokes every lease of a lost connection itself; nothing to retry.
      this.log.warn('lease revoke failed', { lease_id: leaseId, error: describe(error) })
    }
  }

  /**
   * One batched renew. Expired leases are dropped and, if still wanted, registered again.
   * `foreign` is only ever non-empty in the fault-injection build: ids this table does not
   * hold, presented to show that Core refuses them (L-07 negative).
   */
  async renew(foreign: string[] = []): Promise<RenewResult> {
    const leaseIds = this.ids()
    const presented = foreign.filter(id => !this.byLease.has(id))
    if (!leaseIds.length && !presented.length) return { renewed: [], expired: [] }
    const result = await this.core.request<RenewResult>('host.lease.renew', { lease_ids: [...leaseIds, ...presented] })
    if (presented.length) {
      this.log.warn('foreign lease ids presented', {
        presented,
        renewed: result.renewed.filter(id => presented.includes(id)),
        expired: result.expired.filter(id => presented.includes(id)),
      })
    }
    for (const leaseId of result.expired) {
      const registration = this.byLease.get(leaseId)
      this.byLease.delete(leaseId)
      if (!registration) continue
      registration.leaseId = undefined
      if (registration.revoked || registration.instance.mode !== 'active') continue
      this.log.warn('lease expired; registering again', { lease_id: leaseId, capability_id: registration.definition.id })
      registration.settling = this.register(registration).catch(error => {
        this.log.error('re-registration failed', { capability_id: registration.definition.id, error: describe(error) })
      })
    }
    return result
  }

  /** Forget everything without talking to Core (the connection is gone). */
  clear(): void {
    for (const registration of this.byLease.values()) registration.leaseId = undefined
    this.byLease.clear()
  }
}
