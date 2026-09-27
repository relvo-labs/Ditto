import { Service, type Context } from '@deepseek-ai/cordis'
import type {
  CapabilityDefinition, CoreEvent, DataArea, DittoApi, DittoMode, EmitOptions, GrantedFile, Json, Lifecycle,
  PermissionDecision, RevokedGrant,
} from './api.ts'
import type { CoreChannel } from './bridge/core-link.ts'
import { PluginDataArea, grantedFile } from './data-area.ts'
import { DittoError, describe } from './errors.ts'
import type { EventBridge } from './events.ts'
import type { LeaseTable } from './leases.ts'
import type { Instance, LifecycleHooks, Registration, Subscription } from './loader/instance.ts'
import type { HostLog } from './log.ts'

export interface DittoBindings {
  /** The instance whose plugin owns `ctx`; throws for code that is not a hosted entry. */
  instanceFor(ctx: Context): Instance
  core: CoreChannel
  leases: LeaseTable
  events: EventBridge
  subscriptions: Map<string, Subscription>
  log: HostLog
}

interface SubscribeResult { subscription_id: string; seq?: number }

/**
 * Root-level `ditto` service (plan/03/03 §3.3). Plugins reach it with
 * `inject: ['ditto']`. Cordis hands every method the caller's context, so one
 * service instance serves every entry and still knows who is calling. The
 * Context itself never crosses the process boundary; only protocol messages do.
 */
export class DittoService extends Service implements DittoApi {
  constructor(ctx: Context, private readonly bindings: DittoBindings) {
    super(ctx, 'ditto')
  }

  private get instance(): Instance { return this.bindings.instanceFor(this.ctx) }

  get entryId(): string { return this.instance.entryId }
  get mode(): DittoMode { return this.instance.mode }

  get capabilities(): DittoApi['capabilities'] {
    const { ctx, instance, bindings } = this.caller()
    return {
      register: <I, O>(definition: CapabilityDefinition<I, O>) => ctx.effect(() => {
        if (!instance.spec.provides.includes(definition.id)) {
          throw new DittoError('invalid_params', `${definition.id} is not in the manifest provides of ${instance.spec.package}`)
        }
        if (instance.registrations.has(definition.id)) {
          throw new DittoError('conflict', `${definition.id} is already registered by this entry`, { reason: 'single_provider_taken' })
        }
        const registration: Registration = { instance, definition: definition as CapabilityDefinition, revoked: false }
        instance.registrations.set(definition.id, registration)
        // Candidates only record; activation sends the batch (plan/03/03 §4.3).
        // A refusal here is logged by activate(); nothing else awaits this promise.
        if (instance.mode === 'active') registration.settling = activate(bindings, registration).catch(() => {})
        return async () => {
          if (instance.registrations.get(definition.id) === registration) instance.registrations.delete(definition.id)
          await bindings.leases.revoke(registration)
        }
      }, `ditto.capabilities.register(${definition.id})`),
      call: <T>(capabilityId: string, input: Record<string, unknown> = {}) =>
        bindings.core.request<T>(capabilityId, input, { onBehalfOf: instance.entryId }),
    }
  }

  get events(): DittoApi['events'] {
    const { ctx, instance, bindings } = this.caller()
    return {
      emit: (name: string, payload: Json, options: EmitOptions = {}) => {
        const coalesce = options.coalesce ?? declaredCoalesce(instance, name)
        if (instance.mode !== 'active') {
          // A candidate in its isolate realm is not the provider: its events go nowhere. A rebuilt
          // main-realm instance holds them until activation, so an initial event is not lost.
          if (instance.realm === 'main' && instance.heldEvents.length < bindings.events.limit) {
            instance.heldEvents.push({ name, payload, coalesce, ...(options.coalesceKey ? { coalesceKey: options.coalesceKey } : {}) })
          } else {
            bindings.log.debug('event from a candidate dropped', { entry_id: instance.entryId, name })
          }
          return
        }
        bindings.events.emit(instance.entryId, name, payload, coalesce, options.coalesceKey)
      },
      subscribe: (topics: string[], handler: (event: CoreEvent) => void) => ctx.effect(() => {
        const subscription: Subscription = { topics, handler }
        instance.subscriptions.add(subscription)
        let disposed = false
        bindings.core.request<SubscribeResult>('desktop.events.subscribe', { topics }, { onBehalfOf: instance.entryId }).then(result => {
          if (disposed) return
          subscription.subscriptionId = result.subscription_id
          bindings.subscriptions.set(result.subscription_id, subscription)
        }, error => bindings.log.warn('subscription refused', { entry_id: instance.entryId, topics, error: describe(error) }))
        return () => {
          disposed = true
          instance.subscriptions.delete(subscription)
          if (subscription.subscriptionId) bindings.subscriptions.delete(subscription.subscriptionId)
        }
      }, `ditto.events.subscribe(${topics.join(',')})`),
    }
  }

  get data(): DataArea { return new PluginDataArea(this.instance.spec.data_dir) }

  get permissions(): DittoApi['permissions'] {
    const { ctx, instance, bindings } = this.caller()
    return {
      check: async (capabilityId: string, resource?: string): Promise<PermissionDecision> => {
        try {
          const result = await bindings.core.request<{ effective?: string; decision?: string; reason?: string | null }>(
            'desktop.permissions.check',
            { subject: `host:${instance.entryId}`, capability_id: capabilityId, ...(resource !== undefined ? { resource } : {}) },
            { onBehalfOf: instance.entryId },
          )
          // Only an explicit effective `allowed` allows; anything else, malformed answers included, is a denial.
          if (result?.effective === 'allowed') return { decision: 'allowed' }
          return { decision: 'denied', reason: result?.reason ?? result?.effective ?? 'not_granted' }
        } catch (error) {
          return { decision: 'denied', reason: error instanceof DittoError ? (error.reason ?? error.errorName) : 'check_failed' }
        }
      },
      resolveFile: async (grantId: string): Promise<GrantedFile> => {
        // Core sends the path only to the host that holds the grant (HostEntryProjection.file_grants).
        const path = instance.spec.file_grants[grantId]
        if (typeof path !== 'string') {
          throw new DittoError('permission_denied', `file grant ${grantId} is not held by this entry`, { reason: 'not_granted' })
        }
        return grantedFile(grantId, path)
      },
      onRevoked: (handler: (grant: RevokedGrant) => void | Promise<void>) => ctx.effect(() => {
        instance.revokeHandlers.add(handler)
        return () => instance.revokeHandlers.delete(handler)
      }, 'ditto.permissions.onRevoked()'),
    }
  }

  get lifecycle(): Lifecycle {
    const { ctx, instance } = this.caller()
    const hook = <K extends keyof LifecycleHooks>(key: K, label: string) => (fn: NonNullable<LifecycleHooks[K]>) => ctx.effect(() => {
      instance.hooks[key] = fn
      return () => { if (instance.hooks[key] === fn) delete instance.hooks[key] }
    }, `ditto.lifecycle.${label}()`)
    return {
      health: hook('health', 'health'),
      onDrain: hook('drain', 'onDrain'),
      exportState: hook('exportState', 'exportState'),
      importState: hook('importState', 'importState'),
    }
  }

  private caller() {
    return { ctx: this.ctx, instance: this.instance, bindings: this.bindings }
  }
}

async function activate(bindings: DittoBindings, registration: Registration): Promise<void> {
  try {
    await bindings.leases.register(registration)
  } catch (error) {
    bindings.log.error('capability registration refused', {
      entry_id: registration.instance.entryId, capability_id: registration.definition.id, error: describe(error),
    })
    throw error
  }
}

function declaredCoalesce(instance: Instance, name: string): 'none' | 'latest' {
  const events = instance.plugin?.events
  if (!Array.isArray(events)) return 'none'
  const declared = events.find((event: { name?: unknown }) => event?.name === name) as { coalesce?: unknown } | undefined
  return declared?.coalesce === 'latest' ? 'latest' : 'none'
}

/** Events held before activation go out in emit order once the instance is active. */
export function releaseHeldEvents(events: EventBridge, instance: Instance): void {
  for (const event of instance.heldEvents.splice(0)) events.emit(instance.entryId, event.name, event.payload, event.coalesce, event.coalesceKey)
}

/** Registrations of a newly active instance go to Core as one batch. */
export async function activateRegistrations(bindings: Pick<DittoBindings, 'leases' | 'log'>, instance: Instance): Promise<void> {
  const pending = [...instance.registrations.values()].map(registration => {
    const attempt = activate(bindings as DittoBindings, registration)
    registration.settling = attempt.catch(() => {})
    return attempt
  })
  const results = await Promise.allSettled(pending)
  const refused = results.find((result): result is PromiseRejectedResult => result.status === 'rejected')
  if (refused) throw refused.reason
}
