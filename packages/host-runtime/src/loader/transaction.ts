import { resolveConfig, type Context, type Plugin } from '@deepseek-ai/cordis'
import { deepEqual } from '@deepseek-ai/cosmokit'
import { equalExceptVolatile } from '@deepseek-ai/cordis-plugin-loader/diff'
import type { Json } from '../api.ts'
import { activateRegistrations, releaseHeldEvents } from '../ditto-service.ts'
import type { EventBridge } from '../events.ts'
import { DittoError, describe } from '../errors.ts'
import { faultPoint, type FaultPoint } from '../fault.ts'
import { FiberState, fiberStateName, type FiberStateName } from '../fiber-state.ts'
import type { LeaseTable } from '../leases.ts'
import type { HostLog } from '../log.ts'
import { waitingFor } from '../resources.ts'
import { Instance } from './instance.ts'
import type { ModulePolicy } from './module-policy.ts'
import { parseProjection, sameCode, type HostEntrySpec } from './projection.ts'

/** D-32 (proposal): one strategy per hostd build; `host.hello.strategy` announces it. */
export type Strategy = 'isolate_rebuild' | 'in_place'

export type Phase =
  | 'preparing' | 'prepared' | 'aborting' | 'aborted'
  | 'committing' | 'committed' | 'rolling_back' | 'rolled_back'

type PlanKind = 'add' | 'replace' | 'remove' | 'volatile' | 'keep'

export interface PrepareItem { key: string; status: 'ready' | 'failed' | 'pending'; reason?: string; missing?: string[] }
export interface CommitItem { key: string; status: 'applied' | 'failed'; reason?: string }
export interface RollbackItem { key: string; status: 'restored' | 'not_restored'; reason?: string }

/** Mirrors ditto_protocol::participant::HostEntryObservation (empty/absent fields are omitted, as serde skips them). */
export interface HostObservationEntry {
  entry_id: string
  fiber_state: FiberStateName
  mode: 'candidate' | 'active'
  waiting_for?: string[]
  failure?: string
}

/** Wire phases (ParticipantPhase); transient local phases report the last settled one. */
export type WirePhase = 'prepared' | 'committed' | 'aborted' | 'rolled_back' | 'unknown'
const wirePhase: Record<Phase, WirePhase> = {
  preparing: 'unknown', prepared: 'prepared', aborting: 'prepared', aborted: 'aborted',
  committing: 'prepared', committed: 'committed', rolling_back: 'committed', rolled_back: 'rolled_back',
}
export interface HostObservation { role: 'hostd'; entries: HostObservationEntry[] }

interface PluginShape {
  name?: string
  inject?: string[] | Record<string, unknown>
  services?: string[]
  provide?: string
  events?: unknown
  Config?: Plugin.Runtime['Config']
}

interface Plan {
  kind: PlanKind
  entryId: string
  before?: Instance
  /** The spec `before` had at prepare time; volatile rollback needs it after commit replaced it. */
  previous?: HostEntrySpec
  target?: HostEntrySpec
  plugin?: PluginShape
  candidate?: Instance
  candidateHealthy?: boolean
  prepare: PrepareItem
  exported?: Json
  after?: Instance
  commit?: CommitItem
}

interface Txn {
  changeId: string
  origin: string
  phase: Phase
  plans: Plan[]
  prepareMs?: number
  commitMs?: number
  /** entry_id → ms without a leased provider during commit (old instance gone → new one active). */
  gaps: Record<string, number>
}

export interface TransactionOptions {
  root: Context
  strategy: Strategy
  policy: ModulePolicy
  leases: LeaseTable
  events: EventBridge
  log: HostLog
  /** How long a PENDING fiber may wait for its services during prepare/commit (plan/03/03 §4.4). */
  pendingWaitMs?: number
  drainTimeoutMs?: number
  faults?: (point: FaultPoint) => Promise<void>
  /** Called when observable entry state may have changed. */
  onChange?: () => void
  /** Called when a mount's disposers have all finished, so its memory can be collected (reclaim.ts). */
  reclaim?: () => void
}

export interface TransactionStats {
  /** Strategy A: candidate passed its health check but the rebuilt main-realm instance did not (D-32 criterion ③). */
  candidateHealthyRebuildUnhealthy: number
}

const maxStateBytes = 1_048_576
const rememberedChanges = 64


async function withTimeout<T>(task: Promise<T>, ms: number, onTimeout?: () => void): Promise<{ value: T } | { timeout: true }> {
  let timer: NodeJS.Timeout | undefined
  const timeout = new Promise<{ timeout: true }>(resolve => {
    timer = setTimeout(() => { onTimeout?.(); resolve({ timeout: true }) }, ms)
    timer.unref()
  })
  try {
    return await Promise.race([task.then(value => ({ value })), timeout])
  } finally {
    clearTimeout(timer)
  }
}

function servicesOf(plugin: PluginShape | undefined): string[] {
  if (!plugin) return []
  const names = new Set(Array.isArray(plugin.services) ? plugin.services : [])
  if (typeof plugin.provide === 'string') names.add(plugin.provide)
  return [...names]
}

function injectsOf(plugin: PluginShape | undefined): string[] {
  const inject = plugin?.inject
  if (!inject) return []
  return Array.isArray(inject) ? inject : Object.keys(inject)
}

/**
 * `ditto-host-loader`: the transaction layer over the eager, non-transactional
 * Cordis loader (harness modification #8). It is the only code in hostd that
 * calls `ctx.loader.create/update/remove`. Transactions, candidates, handoff and
 * rollback are Ditto's; Cordis only mounts and disposes fibers.
 */
export class TransactionLayer {
  /** entry_id → the main-realm instance serving it. */
  readonly active = new Map<string, Instance>()
  /** loader id → every live mount, candidates included, until its disposal completes. */
  readonly instances = new Map<string, Instance>()
  /** entry_id → why it may not be mounted again (cleanup timed out). */
  readonly faulted = new Map<string, string>()
  readonly stats: TransactionStats = { candidateHealthyRebuildUnhealthy: 0 }

  private readonly disposing = new Map<string, Promise<void>>()
  private readonly changes = new Map<string, Txn>()
  private current?: Txn
  private queue: Promise<unknown> = Promise.resolve()
  private statusWaiters = new Set<() => void>()
  private realmSequence = 0

  private readonly pendingWaitMs: number
  private readonly drainTimeoutMs: number
  private readonly faults: (point: FaultPoint) => Promise<void>

  constructor(private readonly options: TransactionOptions) {
    this.pendingWaitMs = options.pendingWaitMs ?? 3_000
    this.drainTimeoutMs = options.drainTimeoutMs ?? 3_000
    this.faults = options.faults ?? faultPoint
    options.root.on('internal/status', () => {
      for (const wake of this.statusWaiters) wake()
      options.onChange?.()
    })
  }

  get strategy(): Strategy { return this.options.strategy }
  private get loader() { return this.options.root.loader }
  private get log() { return this.options.log }

  // ── participant methods ────────────────────────────────────────────────

  prepare(params: unknown): Promise<{ items: PrepareItem[] }> {
    return this.serial(() => this.doPrepare(params))
  }

  commit(params: unknown): Promise<{ items: CommitItem[] }> {
    return this.serial(() => this.doCommit(this.txnFor(params, ['prepared'])))
  }

  abort(params: unknown): Promise<Record<string, never>> {
    return this.serial(async () => {
      const txn = this.lookup(params)
      if (!txn) return {}
      if (txn.phase === 'prepared' || txn.phase === 'preparing') await this.doAbort(txn)
      return {}
    })
  }

  rollback(params: unknown): Promise<{ items: RollbackItem[] }> {
    return this.serial(async () => {
      const txn = this.lookup(params)
      if (!txn) throw new DittoError('not_found', 'change is not remembered by this hostd', { reason: 'unknown_change' })
      if (txn.phase === 'prepared') {
        await this.doAbort(txn)
        return { items: txn.plans.map(plan => ({ key: plan.entryId, status: 'restored' as const })) }
      }
      if (txn.phase !== 'committed' && txn.phase !== 'committing') {
        throw new DittoError('conflict', `change is ${txn.phase}`, { reason: 'change_in_progress' })
      }
      return this.doRollback(txn)
    })
  }

  /** Answers from memory only; a restarted hostd does not remember and says so (L-06 negative). */
  state(params: unknown): { change: { change_id: string; phase: WirePhase } | null; observed: HostObservation } {
    const changeId = (params as { change_id?: unknown } | undefined)?.change_id
    let change: { change_id: string; phase: WirePhase } | null = null
    if (typeof changeId === 'string') {
      const known = this.changes.get(changeId)
      change = { change_id: changeId, phase: known ? wirePhase[known.phase] : 'unknown' }
    } else if (this.current) change = { change_id: this.current.changeId, phase: wirePhase[this.current.phase] }
    return { change, observed: this.observation() }
  }

  observation(): HostObservation {
    const entries: HostObservationEntry[] = [...this.active.values()].map(instance => {
      const waiting = waitingFor(instance)
      return {
        entry_id: instance.entryId,
        fiber_state: instance.failure ? 'failed' : instance.fiber ? fiberStateName(instance.fiber.state) : 'pending',
        mode: instance.mode,
        ...(waiting.length ? { waiting_for: waiting } : {}),
        ...(instance.failure ? { failure: instance.failure } : {}),
      }
    })
    for (const [entryId, reason] of this.faulted) {
      if (!this.active.has(entryId)) entries.push({ entry_id: entryId, fiber_state: 'failed', mode: 'candidate', failure: reason })
    }
    return { role: 'hostd', entries }
  }

  timings(changeId: string): { prepareMs?: number; commitMs?: number; gaps: Record<string, number> } | undefined {
    const txn = this.changes.get(changeId)
    return txn && { ...(txn.prepareMs !== undefined ? { prepareMs: txn.prepareMs } : {}), ...(txn.commitMs !== undefined ? { commitMs: txn.commitMs } : {}), gaps: { ...txn.gaps } }
  }

  /** Mounts of one entry that have not finished disposing, per realm. L-08 asserts `main` never exceeds 1. */
  liveMounts(entryId: string, realm: 'main' | 'candidate'): number {
    let count = 0
    for (const instance of this.instances.values()) if (instance.entryId === entryId && instance.realm === realm) count += 1
    return count
  }

  /** hostd shutdown: dispose everything, bounded by each entry's cleanup timeout. */
  async disposeAll(): Promise<void> {
    await this.serial(() => Promise.all([...this.instances.values()].map(instance => this.dispose(instance))))
  }

  /** The instance whose plugin owns `ctx`; used by the `ditto` service. */
  instanceFor(ctx: Context): Instance {
    let fiber = ctx.fiber
    while (fiber) {
      const loaderId = fiber.entry?.options.id
      const instance = loaderId ? this.instances.get(loaderId) : undefined
      if (instance) return instance
      const next = fiber.parent.fiber
      if (next === fiber) break
      fiber = next
    }
    throw new DittoError('identity_rejected', 'ctx.ditto is only available to entries Core pushed to this hostd')
  }

  instancesOf(entryId: string): Instance[] {
    return [...this.instances.values()].filter(instance => instance.entryId === entryId)
  }

  // ── prepare ────────────────────────────────────────────────────────────

  private async doPrepare(params: unknown): Promise<{ items: PrepareItem[] }> {
    const { change_id: changeId, origin = 'changeset', target } = (params ?? {}) as { change_id?: unknown; origin?: unknown; target?: unknown }
    if (typeof changeId !== 'string' || !changeId) throw new DittoError('invalid_params', 'change_id is required')
    const known = this.changes.get(changeId)
    if (known) {
      // A resent prepare gets the recorded answer, not a second set of candidates.
      if (known.phase === 'prepared') return { items: known.plans.map(plan => plan.prepare) }
      throw new DittoError('conflict', `change ${changeId} is ${known.phase}`, { reason: 'change_in_progress' })
    }
    if (this.current && this.current.phase === 'prepared') {
      throw new DittoError('conflict', `change ${this.current.changeId} is still prepared`, { reason: 'change_in_progress' })
    }
    const projection = parseProjection(target)
    const started = performance.now()
    const txn: Txn = { changeId, origin: String(origin), phase: 'preparing', plans: [], gaps: {} }
    this.remember(txn)
    await this.faults('prepare.before')

    txn.plans = this.diff(projection.entries)
    // Import every module that will be mounted; the import also tells which services it provides.
    await Promise.all(txn.plans.map(async plan => {
      if (plan.kind !== 'add' && plan.kind !== 'replace') return
      try {
        plan.plugin = await this.importPlugin(plan.target!)
      } catch (error) {
        plan.prepare = { key: plan.entryId, status: 'failed', reason: `module_load_failed: ${describe(error)}` }
      }
    }))

    if (this.strategy === 'isolate_rebuild') await this.prepareCandidates(txn)
    else await this.prepareStatic(txn)
    await this.faults('prepare.after_mount')

    txn.phase = 'prepared'
    txn.prepareMs = performance.now() - started
    return { items: txn.plans.map(plan => plan.prepare) }
  }

  private diff(targets: HostEntrySpec[]): Plan[] {
    const plans: Plan[] = []
    const seen = new Set<string>()
    for (const target of targets) {
      seen.add(target.entry_id)
      const before = this.active.get(target.entry_id)
      const plan = (kind: PlanKind, prepare?: Partial<PrepareItem>): Plan => ({
        kind, entryId: target.entry_id, ...(before ? { before, previous: before.spec } : {}), target,
        prepare: { key: target.entry_id, status: 'ready', ...prepare } as PrepareItem,
      })
      const faulted = this.faulted.get(target.entry_id)
      if (target.disabled) {
        plans.push(before ? plan('remove') : plan('keep'))
      } else if (faulted && (!before || !sameCode(before.spec, target))) {
        // L-08 negative: an entry whose cleanup never finished is not mounted a second time.
        plans.push(plan('keep', { status: 'failed', reason: `entry_faulted: ${faulted}` }))
      } else if (!before) {
        plans.push(plan('add'))
      } else if (!sameCode(before.spec, target) || !deepEqual(before.spec.file_grants, target.file_grants, true)
        || before.failure || before.fiber?.state === FiberState.FAILED) {
        // A new or moved file grant means a new instance: plugins resolve grants when they start.
        plans.push(plan('replace'))
      } else if (!deepEqual(before.spec.config, target.config, true)) {
        const volatile = this.volatileOnly(before, target)
        if (volatile === 'invalid') plans.push(plan('volatile', { status: 'failed', reason: 'config_invalid' }))
        else plans.push(plan(volatile ? 'volatile' : 'replace'))
      } else {
        plans.push(plan('keep'))
      }
    }
    for (const [entryId, before] of this.active) {
      if (seen.has(entryId)) continue
      plans.push({ kind: 'remove', entryId, before, previous: before.spec, prepare: { key: entryId, status: 'ready' } })
    }
    return plans
  }

  /** A config change that only touches `.volatile()` fields is committed without a remount (harness #22). */
  private volatileOnly(before: Instance, target: HostEntrySpec): boolean | 'invalid' {
    const fiber = before.fiber
    const runtime = fiber?.runtime
    if (!fiber || !runtime || fiber.state !== FiberState.ACTIVE) return false
    if (!equalExceptVolatile(before.spec.config, target.config, runtime.Config)) return false
    let candidate: unknown
    try { candidate = resolveConfig(runtime, structuredClone(target.config)) } catch { return 'invalid' }
    return deepEqual(fiber.config, candidate, true)
  }

  /** Strategy A: mount candidates in an isolate realm; the active set is not touched. */
  private async prepareCandidates(txn: Txn): Promise<void> {
    const mounting = txn.plans.filter(plan => (plan.kind === 'add' || plan.kind === 'replace') && plan.prepare.status === 'ready')
    const label = `ditto-candidate-${++this.realmSequence}`
    const isolate = Object.fromEntries(mounting.flatMap(plan => servicesOf(plan.plugin)).map(name => [name, label]))
    for (const plan of mounting) {
      try {
        plan.candidate = await this.mount(plan.target!, 'candidate', txn.changeId, isolate)
      } catch (error) {
        plan.prepare = { key: plan.entryId, status: 'failed', reason: error instanceof DittoError ? (error.reason ?? describe(error)) : describe(error) }
      }
    }
    await Promise.all(mounting.filter(plan => plan.candidate).map(async plan => {
      const outcome = await this.settle(plan.candidate!)
      if (outcome.status !== 'ready') {
        plan.prepare = { key: plan.entryId, ...outcome }
        return
      }
      const health = await this.health(plan.candidate!)
      plan.candidateHealthy = health.ok
      if (!health.ok) plan.prepare = { key: plan.entryId, status: 'failed', reason: health.reason! }
    }))
  }

  /** Strategy B: static checks only; nothing is mounted before commit. */
  private async prepareStatic(txn: Txn): Promise<void> {
    const mounting = txn.plans.filter(plan => (plan.kind === 'add' || plan.kind === 'replace') && plan.prepare.status === 'ready')
    const providedHere = new Set(mounting.flatMap(plan => servicesOf(plan.plugin)))
    const deadline = Date.now() + this.pendingWaitMs
    for (const plan of mounting) {
      try {
        resolveConfig({ Config: plan.plugin!.Config } as Plugin.Runtime, structuredClone(plan.target!.config))
      } catch (error) {
        plan.prepare = { key: plan.entryId, status: 'failed', reason: `config_invalid: ${describe(error)}` }
        continue
      }
      let missing = this.unprovided(plan.plugin, providedHere)
      while (missing.length && Date.now() < deadline) {
        await this.statusChange(deadline - Date.now())
        missing = this.unprovided(plan.plugin, providedHere)
      }
      if (missing.length) plan.prepare = { key: plan.entryId, status: 'failed', reason: `dependency_not_ready: ${missing.join(', ')}`, missing }
    }
  }

  private unprovided(plugin: PluginShape | undefined, providedHere: Set<string>): string[] {
    return injectsOf(plugin).filter(name => !providedHere.has(name) && this.options.root.get(name) === undefined)
  }

  // ── commit ─────────────────────────────────────────────────────────────

  private async doCommit(txn: Txn): Promise<{ items: CommitItem[] }> {
    const started = performance.now()
    txn.phase = 'committing'
    await this.faults('commit.before')
    const gapStart = new Map<string, number>()

    // 1. Strategy A: candidates go first. Cordis cannot promote an isolate instance to the main
    //    realm, and a candidate that cannot clean up must fail the entry before the old one is touched.
    await Promise.all(txn.plans.map(async plan => {
      if (!plan.candidate) return
      if (await this.dispose(plan.candidate) === 'timeout') plan.commit = { key: plan.entryId, status: 'failed', reason: 'candidate_cleanup_timeout' }
    }))

    // 2. Old instances hand off and go away, one ordered sequence per entry.
    for (const plan of txn.plans) {
      if ((plan.kind !== 'replace' && plan.kind !== 'remove') || !plan.before || plan.commit) continue
      gapStart.set(plan.entryId, performance.now())
      plan.exported = await this.handOff(plan.before, plan.kind === 'replace')
      await this.faults('commit.after_drain')
      const result = await this.dispose(plan.before)
      this.active.delete(plan.entryId)
      if (result === 'timeout') plan.commit = { key: plan.entryId, status: 'failed', reason: 'cleanup_timeout' }
    }
    await this.faults('commit.after_dispose')

    // 3. Mount in the main realm together, so rebuilt providers and consumers resolve each other.
    const mounting = txn.plans.filter(plan => (plan.kind === 'add' || plan.kind === 'replace') && !plan.commit)
    for (const plan of mounting) {
      if (!gapStart.has(plan.entryId)) gapStart.set(plan.entryId, performance.now())
      try {
        plan.after = await this.mount(plan.target!, 'main', txn.changeId)
      } catch (error) {
        plan.commit = { key: plan.entryId, status: 'failed', reason: error instanceof DittoError ? (error.reason ?? describe(error)) : describe(error) }
      }
    }
    await Promise.all(mounting.filter(plan => plan.after).map(async plan => {
      const reason = await this.bringUp(plan.after!, plan.exported)
      if (reason) {
        if (plan.candidateHealthy) this.stats.candidateHealthyRebuildUnhealthy += 1
        plan.commit = { key: plan.entryId, status: 'failed', reason }
        await this.dispose(plan.after!)
        return
      }
      this.active.set(plan.entryId, plan.after!)
      // Not on the wire (ItemReport has no such field); kept for the result text and the D-32 trial.
      txn.gaps[plan.entryId] = performance.now() - gapStart.get(plan.entryId)!
      plan.commit = { key: plan.entryId, status: 'applied' }
    }))

    // 4. Volatile-only config: committed into the running fiber, no remount.
    for (const plan of txn.plans) {
      if (plan.kind === 'volatile' && plan.prepare.status === 'ready') plan.commit = await this.applyVolatile(plan.before!, plan.target!)
      if (plan.kind === 'keep' && plan.before && plan.target) plan.before.spec = plan.target
      plan.commit ??= { key: plan.entryId, status: plan.prepare.status === 'failed' ? 'failed' : 'applied', ...(plan.prepare.reason ? { reason: plan.prepare.reason } : {}) }
    }

    txn.phase = 'committed'
    txn.commitMs = performance.now() - started
    const items = txn.plans.map(plan => plan.commit!)
    // A recent change remains addressable for state queries and rollback, but
    // disposed candidates and old fibers must not be kept alive by that log.
    // Rollback only needs the previous spec and exported data; a volatile
    // update also needs its still-active instance.
    for (const plan of txn.plans) {
      if (plan.kind !== 'volatile') plan.before = undefined
      plan.candidate = undefined
      plan.after = undefined
      plan.plugin = undefined
      plan.target = undefined
    }
    if (this.current === txn) this.current = undefined
    this.options.onChange?.()
    return { items }
  }

  /** Settle, import handed-off state, health-check, then send held registrations. Returns a failure reason or nothing. */
  private async bringUp(instance: Instance, state: Json | undefined): Promise<string | undefined> {
    const outcome = await this.settle(instance)
    if (outcome.status !== 'ready') return outcome.reason
    if (state !== undefined && instance.hooks.importState) {
      try { await instance.hooks.importState(state) } catch (error) { return `import_failed: ${describe(error)}` }
    }
    const health = await this.health(instance)
    if (!health.ok) return health.reason
    instance.mode = 'active'
    try {
      await activateRegistrations(this.options, instance)
    } catch (error) {
      instance.mode = 'candidate'
      instance.heldEvents.length = 0
      return error instanceof DittoError ? `registration_refused: ${error.reason ?? error.errorName}` : `registration_refused: ${describe(error)}`
    }
    releaseHeldEvents(this.options.events, instance)
    this.options.onChange?.()
    return undefined
  }

  private async applyVolatile(instance: Instance, target: HostEntrySpec): Promise<CommitItem> {
    const fiber = instance.fiber
    try {
      await this.loader.update(instance.loaderId, { config: structuredClone(target.config) })
    } catch (error) {
      return { key: instance.entryId, status: 'failed', reason: `volatile_update_failed: ${describe(error)}` }
    }
    // Readback of our own claim: the same fiber must still be ACTIVE (no remount happened).
    if (instance.fiber !== fiber || fiber?.state !== FiberState.ACTIVE) {
      return { key: instance.entryId, status: 'failed', reason: 'volatile_update_remounted' }
    }
    instance.spec = target
    return { key: instance.entryId, status: 'applied' }
  }

  // ── abort and rollback ─────────────────────────────────────────────────

  /** Resolves only after every candidate, async disposers included, has finished (or timed out). */
  private async doAbort(txn: Txn): Promise<void> {
    txn.phase = 'aborting'
    await this.faults('abort.before')
    await Promise.all(txn.plans.map(plan => plan.candidate && this.dispose(plan.candidate)))
    txn.phase = 'aborted'
    txn.plans = txn.plans.map(plan => ({ kind: 'keep', entryId: plan.entryId, prepare: plan.prepare }))
    if (this.current === txn) this.current = undefined
  }

  private async doRollback(txn: Txn): Promise<{ items: RollbackItem[] }> {
    txn.phase = 'rolling_back'
    await this.faults('rollback.before')
    const items: RollbackItem[] = []
    for (const plan of [...txn.plans].reverse()) {
      if (plan.kind === 'keep') {
        items.push({ key: plan.entryId, status: 'restored' })
        continue
      }
      if (plan.kind === 'volatile') {
        const result = plan.commit?.status === 'applied' ? await this.applyVolatile(plan.before!, plan.previous!) : undefined
        items.push(result && result.status !== 'applied' ? { key: plan.entryId, status: 'not_restored', reason: result.reason! } : { key: plan.entryId, status: 'restored' })
        continue
      }
      const current = this.active.get(plan.entryId)
      let state = plan.exported
      if (current) {
        state = (await this.handOff(current, true)) ?? state
        const result = await this.dispose(current)
        this.active.delete(plan.entryId)
        if (result === 'timeout') {
          items.push({ key: plan.entryId, status: 'not_restored', reason: 'cleanup_timeout' })
          continue
        }
      }
      if (!plan.previous || plan.previous.disabled) {
        items.push({ key: plan.entryId, status: 'restored' })
        continue
      }
      try {
        const restored = await this.mount(plan.previous, 'main', txn.changeId)
        const reason = await this.bringUp(restored, state)
        if (reason) {
          await this.dispose(restored)
          items.push({ key: plan.entryId, status: 'not_restored', reason })
        } else {
          this.active.set(plan.entryId, restored)
          items.push({ key: plan.entryId, status: 'restored' })
        }
      } catch (error) {
        items.push({ key: plan.entryId, status: 'not_restored', reason: error instanceof DittoError ? (error.reason ?? describe(error)) : describe(error) })
      }
    }
    txn.phase = 'rolled_back'
    txn.plans = []
    if (this.current === txn) this.current = undefined
    this.options.onChange?.()
    return { items: items.reverse() }
  }

  // ── mounting primitives ────────────────────────────────────────────────

  private async importPlugin(spec: HostEntrySpec): Promise<PluginShape> {
    this.options.policy.admit(spec.module_path)
    const url = this.options.policy.resolve(spec.module_path)
    const exports = await import(/* @vite-ignore */ url)
    const plugin = this.loader.unwrapExports(exports) as PluginShape | undefined
    // Same shapes Cordis' registry accepts: a function, or an object with an apply method.
    if (typeof plugin !== 'function' && typeof (plugin as { apply?: unknown } | undefined)?.apply !== 'function') {
      throw new Error('module does not export a Cordis plugin (a function or an object with apply)')
    }
    return plugin as PluginShape
  }

  private async mount(spec: HostEntrySpec, realm: 'main' | 'candidate', changeId: string, isolate?: Record<string, string>): Promise<Instance> {
    if (realm === 'main') await this.waitDisposal(spec.entry_id, spec.cleanup_timeout_ms)
    const instance = new Instance(spec, realm, changeId)
    // Cached by Node after prepare's import; the plugin object carries `services` and `events`.
    instance.plugin = await this.importPlugin(spec)
    this.instances.set(instance.loaderId, instance)
    const options = {
      id: instance.loaderId,
      name: spec.module_path,
      config: structuredClone(spec.config),
      ...(isolate && Object.keys(isolate).length ? { isolate } : {}),
    }
    try {
      // EntryTree.create honours a caller-supplied id; Core's entry ids never collide with ours.
      await this.loader.create(options as Parameters<typeof this.loader.create>[0])
    } catch (error) {
      // e.g. the export is not a plugin shape Cordis accepts. Leave nothing behind.
      try { this.loader.remove(instance.loaderId) } catch { /* never created */ }
      this.instances.delete(instance.loaderId)
      throw new DittoError('invalid_params', `module is not a Cordis plugin: ${describe(error)}`, { reason: `module_invalid: ${describe(error)}` })
    }
    instance.fiber = this.loader.resolve(instance.loaderId).fiber
    instance.mountedAt = performance.now()
    if (!instance.fiber) instance.failure = 'module_load_failed'
    return instance
  }

  /** Wait until the fiber is ACTIVE, FAILED, or has been PENDING/LOADING for pendingWaitMs. */
  private async settle(instance: Instance): Promise<Omit<PrepareItem, 'key'>> {
    const fiber = instance.fiber
    if (!fiber) return { status: 'failed', reason: instance.failure ?? 'module_load_failed' }
    const deadline = Date.now() + this.pendingWaitMs
    while (true) {
      const left = deadline - Date.now()
      const loaded = await withTimeout(fiber.await().then(() => undefined, (error: unknown) => error ?? new Error('apply failed')), Math.max(1, left))
      if ('timeout' in loaded) return { status: 'failed', reason: 'apply_timeout' }
      if (loaded.value !== undefined) return { status: 'failed', reason: `apply_failed: ${describe(loaded.value)}` }
      if (fiber.state === FiberState.ACTIVE) return { status: 'ready' }
      if (fiber.state !== FiberState.PENDING) return { status: 'failed', reason: `fiber_${fiberStateName(fiber.state)}` }
      if (deadline - Date.now() <= 0) {
        // PENDING is a legal state meaning "waiting for these services"; prepare bounds the wait.
        const missing = waitingFor(instance)
        return { status: 'failed', reason: `dependency_not_ready: ${missing.join(', ')}`, missing }
      }
      await this.statusChange(deadline - Date.now())
    }
  }

  private async health(instance: Instance): Promise<{ ok: boolean; reason?: string }> {
    if (instance.fiber?.state !== FiberState.ACTIVE) return { ok: false, reason: 'not_active' }
    const check = instance.hooks.health
    if (!check) return { ok: true }
    const controller = new AbortController()
    try {
      const result = await withTimeout(Promise.resolve().then(() => check(controller.signal)), instance.spec.health_timeout_ms, () => controller.abort())
      if ('timeout' in result) return { ok: false, reason: 'health_timeout' }
      if (!result.value?.healthy) return { ok: false, reason: `unhealthy${result.value?.detail ? `: ${result.value.detail}` : ''}` }
      return { ok: true }
    } catch (error) {
      return { ok: false, reason: `health_failed: ${describe(error)}` }
    }
  }

  /** drain → export, as one ordered sequence (async disposers would run concurrently). */
  private async handOff(instance: Instance, exportState: boolean): Promise<Json | undefined> {
    const { drain, exportState: exporter } = instance.hooks
    if (drain) {
      const controller = new AbortController()
      try {
        const result = await withTimeout(Promise.resolve().then(() => drain(controller.signal)), this.drainTimeoutMs, () => controller.abort())
        if ('timeout' in result) this.log.warn('drain timed out; cancelling in-flight work', { entry_id: instance.entryId })
      } catch (error) {
        this.log.warn('drain failed', { entry_id: instance.entryId, error })
      }
    }
    if (!exportState || !exporter) return undefined
    try {
      const state = await exporter()
      const size = Buffer.byteLength(JSON.stringify(state) ?? '')
      if (size > maxStateBytes) {
        this.log.error('exported state exceeds 1 MiB; not handed over', { entry_id: instance.entryId, bytes: size })
        return undefined
      }
      return structuredClone(state)
    } catch (error) {
      this.log.error('exportState failed', { entry_id: instance.entryId, error })
      return undefined
    }
  }

  /** Dispose and wait for every disposer, bounded by the entry's cleanup timeout. */
  private dispose(instance: Instance): Promise<'done' | 'timeout'> {
    if (instance.disposal) return instance.disposal
    const fiber = instance.fiber
    // The first dispose() call returns the settling promise; later calls return nothing.
    const task = (fiber?.uid !== null && fiber ? Promise.resolve(fiber.dispose()) : Promise.resolve())
      .catch(error => this.log.error('dispose failed', { entry_id: instance.entryId, error }))
    try { this.loader.remove(instance.loaderId) } catch { /* never created */ }
    const finished = task.then(() => {
      this.instances.delete(instance.loaderId)
      if (this.disposing.get(instance.entryId) === finished) this.disposing.delete(instance.entryId)
      if (this.faulted.get(instance.entryId) === 'cleanup_timeout' && !this.hasPendingDisposal(instance.entryId)) {
        this.faulted.delete(instance.entryId)
        this.log.info('late cleanup finished; entry may be mounted again', { entry_id: instance.entryId })
      }
      this.options.onChange?.()
      this.options.reclaim?.()
    })
    if (instance.realm === 'main') this.disposing.set(instance.entryId, finished)
    instance.disposal = withTimeout(finished, instance.spec.cleanup_timeout_ms).then(result => {
      if (!('timeout' in result)) return 'done' as const
      instance.failure = 'cleanup_timeout'
      if (instance.realm === 'main' || !this.active.has(instance.entryId)) this.faulted.set(instance.entryId, 'cleanup_timeout')
      this.log.error('cleanup timed out; entry marked faulted', { entry_id: instance.entryId, timeout_ms: instance.spec.cleanup_timeout_ms })
      return 'timeout' as const
    })
    return instance.disposal
  }

  private hasPendingDisposal(entryId: string): boolean {
    return [...this.instances.values()].some(instance => instance.entryId === entryId && instance.disposal)
  }

  /** L-08: a second main-realm mount waits for the previous cleanup, and is refused if it never ends. */
  private async waitDisposal(entryId: string, timeoutMs: number): Promise<void> {
    const faulted = this.faulted.get(entryId)
    if (faulted) throw new DittoError('conflict', `entry ${entryId} is faulted (${faulted})`, { reason: `entry_faulted: ${faulted}` })
    const pending = this.disposing.get(entryId)
    if (!pending) return
    const result = await withTimeout(pending, timeoutMs)
    if ('timeout' in result) {
      this.faulted.set(entryId, 'cleanup_timeout')
      throw new DittoError('conflict', `previous instance of ${entryId} did not finish cleanup`, { reason: 'entry_faulted: cleanup_timeout' })
    }
  }

  // ── bookkeeping ────────────────────────────────────────────────────────

  private statusChange(timeoutMs: number): Promise<void> {
    return new Promise(resolve => {
      const wake = () => { this.statusWaiters.delete(wake); clearTimeout(timer); resolve() }
      const timer = setTimeout(wake, Math.max(1, timeoutMs))
      timer.unref()
      this.statusWaiters.add(wake)
    })
  }

  private serial<T>(task: () => Promise<T> | T): Promise<T> {
    const run = this.queue.then(task, task)
    this.queue = run.catch(() => {})
    return run
  }

  private remember(txn: Txn): void {
    this.changes.set(txn.changeId, txn)
    this.current = txn
    while (this.changes.size > rememberedChanges) {
      const oldest = this.changes.keys().next().value!
      this.changes.delete(oldest)
    }
  }

  private lookup(params: unknown): Txn | undefined {
    const changeId = (params as { change_id?: unknown } | undefined)?.change_id
    if (typeof changeId !== 'string') throw new DittoError('invalid_params', 'change_id is required')
    return this.changes.get(changeId)
  }

  private txnFor(params: unknown, phases: Phase[]): Txn {
    const txn = this.lookup(params)
    if (!txn) throw new DittoError('not_found', 'change is not remembered by this hostd', { reason: 'unknown_change' })
    if (!phases.includes(txn.phase)) throw new DittoError('conflict', `change is ${txn.phase}`, { reason: 'change_in_progress' })
    return txn
  }
}
