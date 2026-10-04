import { Context } from '@deepseek-ai/cordis'
import { Loader } from '@deepseek-ai/cordis-plugin-loader'
import { TimerService } from '@deepseek-ai/cordis-plugin-timer'
import type { CoreEvent, RevokedGrant } from './api.ts'
import type { CoreChannel, HelloResult } from './bridge/core-link.ts'
import { DittoService } from './ditto-service.ts'
import { DittoError, describe } from './errors.ts'
import { EventBridge } from './events.ts'
import { faultPoint, type FaultPoint } from './fault.ts'
import { LeaseTable } from './leases.ts'
import type { Subscription } from './loader/instance.ts'
import type { ModulePolicy } from './loader/module-policy.ts'
import { TransactionLayer, type Strategy } from './loader/transaction.ts'
import { HostLog, installCordisExporter } from './log.ts'
import { entryState, nodeResources } from './resources.ts'
import { hostInfo } from './version.ts'

export interface HostRuntimeOptions {
  core: CoreChannel
  policy: ModulePolicy
  strategy?: Strategy
  log: HostLog
  pendingWaitMs?: number
  drainTimeoutMs?: number
  faults?: (point: FaultPoint) => Promise<void>
  /** Called when a disposed mount's memory may be collected (main.ts wires reclaim.ts). */
  reclaim?: () => void
  /** Background cadence; tests shorten these. host.hello may override heartbeat. */
  intervals?: Partial<{ heartbeatMs: number; renewMs: number; resourcesMs: number; entryStateMs: number }>
}

interface InvokeParams {
  lease_id?: unknown
  entry_id?: unknown
  capability_id?: unknown
  input?: unknown
  caller?: unknown
  operation_id?: unknown
  deadline_ms?: unknown
}

/** D-32 proposal default; the other strategy exists only for the trial. */
export const defaultStrategy: Strategy = 'isolate_rebuild'

/**
 * ditto-hostd's in-process core: the root Context with the loader, the timer
 * service and the `ditto` bridge, plus the transaction layer. It loads nothing
 * until Core pushes a projection; it has no on-disk entry source.
 */
export class HostRuntime {
  readonly root = new Context()
  readonly leases: LeaseTable
  readonly events: EventBridge
  readonly tx: TransactionLayer
  readonly subscriptions = new Map<string, Subscription>()
  private readonly timers: NodeJS.Timeout[] = []
  private entryStateTimer?: NodeJS.Timeout
  private entryStateDue = false
  private lastEntryState = 0
  private started = false
  private readonly faults: (point: FaultPoint) => Promise<void>

  constructor(private readonly options: HostRuntimeOptions) {
    this.faults = options.faults ?? faultPoint
    this.leases = new LeaseTable(options.core, options.log.child({ part: 'leases' }))
    this.events = new EventBridge(options.core, options.log.child({ part: 'events' }))
    this.tx = new TransactionLayer({
      root: this.root,
      strategy: options.strategy ?? defaultStrategy,
      policy: options.policy,
      leases: this.leases,
      events: this.events,
      log: options.log.child({ part: 'loader' }),
      faults: this.faults,
      onChange: () => this.scheduleEntryState(),
      ...(options.reclaim ? { reclaim: options.reclaim } : {}),
      ...(options.pendingWaitMs !== undefined ? { pendingWaitMs: options.pendingWaitMs } : {}),
      ...(options.drainTimeoutMs !== undefined ? { drainTimeoutMs: options.drainTimeoutMs } : {}),
    })
  }

  get strategy(): Strategy { return this.tx.strategy }

  async start(): Promise<void> {
    if (this.started) return
    this.started = true
    installCordisExporter(this.root, this.options.log.child({ part: 'cordis' }))
    await this.root.plugin(Loader)
    // Module resolution goes only through the policy: Core-pushed paths inside the package store.
    this.root.loader.internal = {
      version: 'v2',
      import: (specifier: string) => import(/* @vite-ignore */ this.options.policy.resolve(specifier)),
    } as unknown as Loader['internal']
    this.guardLoader()
    await this.root.plugin(TimerService)
    new DittoService(this.root, {
      instanceFor: ctx => this.tx.instanceFor(ctx),
      core: this.options.core,
      leases: this.leases,
      events: this.events,
      subscriptions: this.subscriptions,
      log: this.options.log.child({ part: 'ditto' }),
    })
  }

  /** Tripwire for plan/03/03 §13 rule 2. Not isolation: same-process code can still reach `ctx.root.loader`. */
  private guardLoader(): void {
    this.root.on('internal/get', (ctx, name, _error, next) => {
      if (name === 'loader' && ctx.fiber.entry) {
        throw new DittoError('identity_rejected', 'plugins may not use ctx.loader; entries change only through Core transactions')
      }
      return next()
    })
  }

  /** Start heartbeat, lease renewal and resource reports after `host.hello`. */
  startBackground(hello?: Partial<HelloResult>): void {
    const intervals = this.options.intervals ?? {}
    const every = (ms: number, task: () => Promise<unknown>) => {
      const timer = setInterval(() => { task().catch(error => this.options.log.warn('background task failed', { error: describe(error) })) }, ms)
      timer.unref()
      this.timers.push(timer)
    }
    every(intervals.heartbeatMs ?? hello?.heartbeat_interval_ms ?? 2_000, async () => {
      await this.faults('heartbeat')
      await this.options.core.request('host.heartbeat', {})
    })
    every(intervals.renewMs ?? 3_000, async () => {
      await this.faults('lease.renew')
      await this.leases.renew()
    })
    every(intervals.resourcesMs ?? 10_000, () => this.options.core.request('host.resources', { ...nodeResources() }))
  }

  stopBackground(): void {
    for (const timer of this.timers.splice(0)) clearInterval(timer)
    if (this.entryStateTimer) clearTimeout(this.entryStateTimer)
  }

  /** Core-originated requests on the hostd connection. Participant steps are logged with their items. */
  async handleRequest(method: string, params: unknown): Promise<unknown> {
    if (!method.startsWith('participant.') || method === 'participant.state') return this.dispatch(method, params)
    const changeId = (params as { change_id?: unknown } | undefined)?.change_id
    try {
      const result = await this.dispatch(method, params) as { items?: { key: string; status: string; reason?: string }[] }
      this.options.log.info(method, { change_id: changeId, items: result?.items ?? [] })
      return result
    } catch (error) {
      this.options.log.error(`${method} refused`, { change_id: changeId, error: describe(error) })
      throw error
    }
  }

  private async dispatch(method: string, params: unknown): Promise<unknown> {
    switch (method) {
      case 'participant.prepare': return this.tx.prepare(params)
      case 'participant.commit': return this.tx.commit(params)
      case 'participant.abort': return this.tx.abort(params)
      case 'participant.rollback': return this.tx.rollback(params)
      case 'participant.state': return this.tx.state(params)
      case 'host.invoke': return this.invoke(params as InvokeParams)
      default: throw new DittoError('not_found', `hostd does not serve ${method}`)
    }
  }

  handleNotification(method: string, params: unknown): void {
    if (method === 'host.permission_revoked') void this.permissionRevoked(params as RevokedGrant)
    else if (method === 'desktop.events') this.deliverEvent(params as CoreEvent)
  }

  private async invoke(params: InvokeParams): Promise<unknown> {
    await this.faults('invoke.before')
    const registration = typeof params.lease_id === 'string' ? this.leases.lookup(params.lease_id) : undefined
    // Only a live lease routes. A stale lease id (older generation, revoked) is refused.
    if (!registration || registration.revoked || registration.instance.mode !== 'active'
      || registration.instance.entryId !== params.entry_id || registration.definition.id !== params.capability_id) {
      throw new DittoError('unavailable', 'no live registration for this lease', { reason: 'not_bound' })
    }
    const deadlineMs = typeof params.deadline_ms === 'number' ? params.deadline_ms : 2_000
    const controller = new AbortController()
    const timer = setTimeout(() => controller.abort(), deadlineMs)
    timer.unref()
    try {
      let input = params.input ?? {}
      const schema = registration.definition.input
      if (schema) {
        const checked = await schema['~standard'].validate(input)
        if (checked.issues) throw new DittoError('invalid_params', checked.issues.map(issue => issue.message).join('; '))
        input = checked.value
      }
      const work = Promise.resolve(registration.definition.handler(input, {
        caller: typeof params.caller === 'string' ? params.caller : 'unknown',
        ...(typeof params.operation_id === 'string' ? { operationId: params.operation_id } : {}),
        deadlineMs,
        signal: controller.signal,
      }))
      const aborted = new Promise<never>((_, reject) => controller.signal.addEventListener('abort', () => {
        reject(new DittoError('timeout', `${registration.definition.id} exceeded ${deadlineMs} ms`, undefined, 'unknown'))
      }))
      return await Promise.race([work, aborted])
    } finally {
      clearTimeout(timer)
    }
  }

  private async permissionRevoked(grant: RevokedGrant): Promise<void> {
    const instances = this.tx.instancesOf(grant.entry_id)
    // The path is forgotten before any plugin code runs, so a late resolveFile() already fails.
    for (const instance of instances) delete instance.spec.file_grants[grant.grant_id]
    const handlers = instances.flatMap(instance => [...instance.revokeHandlers])
    if (!handlers.length) {
      this.options.log.warn('revocation for an entry with no revoke handler; Core will disable it', { entry_id: grant.entry_id, grant_id: grant.grant_id })
    }
    await Promise.all(handlers.map(async handler => {
      try { await handler(grant) } catch (error) {
        this.options.log.error('revoke handler failed', { entry_id: grant.entry_id, error: describe(error) })
      }
    }))
  }

  private deliverEvent(event: CoreEvent): void {
    const subscription = this.subscriptions.get(event.subscription_id)
    if (!subscription) return
    try { subscription.handler(event) } catch (error) {
      this.options.log.error('event handler failed', { subscription_id: event.subscription_id, error: describe(error) })
    }
  }

  /** `host.entry_state`, at most once per 250 ms (host-protocol §8). */
  private scheduleEntryState(): void {
    if (!this.started) return
    const gap = this.options.intervals?.entryStateMs ?? 250
    if (this.entryStateTimer) { this.entryStateDue = true; return }
    const wait = Math.max(0, this.lastEntryState + gap - Date.now())
    this.entryStateTimer = setTimeout(() => {
      this.entryStateTimer = undefined
      this.lastEntryState = Date.now()
      this.entryStateDue = false
      this.reportEntryState().catch(() => {})
      if (this.entryStateDue) this.scheduleEntryState()
    }, wait)
    this.entryStateTimer.unref()
  }

  async reportEntryState(): Promise<void> {
    const entries = [...this.tx.active.values()].map(entryState)
    for (const [entryId, reason] of this.tx.faulted) {
      if (!this.tx.active.has(entryId)) {
        entries.push({ entry_id: entryId, fiber_state: 'failed', mode: 'candidate', waiting_for: [], failure: reason, effects: 0, timers: 0, subscriptions: 0, capabilities: 0 })
      }
    }
    await this.options.core.request('host.entry_state', { entries })
  }

  helloParams() {
    return { ...hostInfo(), strategy: this.strategy }
  }

  async stop(): Promise<void> {
    this.stopBackground()
    await this.tx.disposeAll()
  }
}
