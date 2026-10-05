import { Context, CordisError, FiberState, type Fiber } from '@deepseek-ai/cordis'
import { Loader } from '@deepseek-ai/cordis-plugin-loader'
import Schema from '@deepseek-ai/schemastery'
import { describe, expect, it } from 'vitest'

/**
 * Pins the harness modification-set items Ditto depends on directly
 * (packages/host-runtime/vendor/README.md; plan/03/03 §14). Cases for #6 follow
 * harness packages/extensions/tool-cordis/tests/cordis-lifecycle.spec.ts. Run
 * on every upstream sync: a failure means an assumption of the transaction
 * layer no longer holds.
 */

async function loaderWith(modules: Record<string, unknown>) {
  const ctx = new Context()
  await ctx.plugin(Loader)
  ctx.loader.internal = {
    version: 'v2',
    async import(specifier: string) {
      if (!(specifier in modules)) throw new Error(`unexpected import ${specifier}`)
      return modules[specifier]
    },
  } as unknown as Loader['internal']
  return ctx
}

describe('harness #6: fiber lifecycle hardening', () => {
  it('an effect is visible to a reentrant owner restart, which awaits its setup and cleanup', async () => {
    const ctx = new Context()
    const setupGate = Promise.withResolvers<void>()
    const cleanupGate = Promise.withResolvers<void>()
    const cleanupStarted = Promise.withResolvers<void>()
    let restarted!: Promise<void>
    let cleanupFinished = false
    ctx.effect(async () => {
      restarted = ctx.fiber.restart()
      await setupGate.promise
      return async () => {
        cleanupStarted.resolve()
        await cleanupGate.promise
        cleanupFinished = true
      }
    }, 'reentrant-restart')
    let settled = false
    void restarted.then(() => { settled = true })
    setupGate.resolve()
    await cleanupStarted.promise
    await Promise.resolve()
    expect(settled).toBe(false)
    cleanupGate.resolve()
    await restarted
    expect(cleanupFinished).toBe(true)
    expect(ctx.fiber.getEffects()).toEqual([])
  })

  it('a synchronous setup failure rolls back the cleanup it already collected', () => {
    const ctx = new Context()
    let cleanups = 0
    expect(() => ctx.effect(function* () {
      yield () => { cleanups += 1 }
      throw new Error('setup failed')
    }, 'throwing-setup')).toThrow('setup failed')
    expect(cleanups).toBe(1)
    expect(ctx.fiber.getEffects()).toEqual([])
  })

  it('creating an effect while the owner is UNLOADING is refused with INACTIVE_EFFECT', async () => {
    const ctx = new Context()
    let refused: unknown
    ctx.effect(() => () => {
      try { ctx.effect(() => () => {}, 'too-late') } catch (error) { refused = error }
    }, 'restart-cleanup')
    await ctx.fiber.restart()
    expect(refused).toBeInstanceOf(CordisError)
    expect((refused as CordisError).code).toBe('INACTIVE_EFFECT')
  })

  it('fiber.dispose() resolves only after async disposers have finished (what participant.abort relies on)', async () => {
    const ctx = new Context()
    let finished = false
    const fiber = await ctx.plugin({
      name: 'slow-cleanup',
      apply(inner: Context) {
        inner.effect(() => async () => {
          await new Promise(resolve => setTimeout(resolve, 50))
          finished = true
        }, 'slow')
      },
    })
    await fiber.dispose()
    expect(finished).toBe(true)
    expect(fiber.state).toBe(FiberState.DISPOSED)
  })

  it('a failing teardown observer is contained so ownership cleanup and other observers complete', async () => {
    const ctx = new Context()
    const errors: unknown[] = []
    ctx.logger.error = ((error: unknown) => { errors.push(error) }) as typeof ctx.logger.error
    const observed: string[] = []
    ctx.on('internal/plugin', fiber => { if (fiber.name === 'contained' && fiber.uid === null) throw new Error('broken observer') })
    ctx.on('internal/plugin', fiber => { if (fiber.name === 'contained' && fiber.uid === null) observed.push('disposed') })
    const child = await ctx.plugin({ name: 'contained', apply() {} })
    await expect(child.dispose()).resolves.toBeUndefined()
    expect(observed).toEqual(['disposed'])
    expect(errors).toHaveLength(1)
  })
})

describe('harness #20: loader entries hold the real fiber', () => {
  it('entry.fiber is the registry fiber, and updating provider and consumer together does not strand the consumer in PENDING', async () => {
    const provider = { name: 'pin-provider', apply(ctx: Context, config: { v: number }) { ctx.provide('pinService', { v: config.v }) } }
    const consumer = { name: 'pin-consumer', inject: ['pinService'], apply() {} }
    const ctx = await loaderWith({ provider, consumer })
    await ctx.loader.create({ id: 'p', name: 'provider', config: { v: 1 } } as never)
    await ctx.loader.create({ id: 'c', name: 'consumer', config: { v: 1 } } as never)
    await ctx.loader.await()
    const entry = ctx.loader.resolve('c')
    const fibers: Fiber[] = [...ctx.registry.values()].flatMap(runtime => [...runtime.fibers])
    expect(fibers.includes(entry.fiber!)).toBe(true)
    expect(typeof (entry.fiber as Fiber).state).toBe('number')

    await Promise.all([
      ctx.loader.update('p', { config: { v: 2 } } as never),
      ctx.loader.update('c', { config: { v: 2 } } as never),
    ])
    await ctx.loader.await()
    expect(ctx.loader.resolve('c').fiber!.state).toBe(FiberState.ACTIVE)
    expect(ctx.loader.resolve('p').fiber!.state).toBe(FiberState.ACTIVE)
  })
})

describe('harness #22: volatile config', () => {
  it('a volatile-only change is committed into the running fiber without a remount and announced once', async () => {
    let applies = 0
    const seen: unknown[] = []
    const plugin = {
      name: 'pin-volatile',
      Config: Schema.object({ label: Schema.string().default('a'), rules: Schema.object({ limit: Schema.number().default(3) }).volatile() }),
      apply(ctx: Context, config: { rules: { get(): { limit: number } } }) {
        applies += 1
        ctx.on('loader/volatile-update', paths => { seen.push({ paths, limit: config.rules.get().limit }) })
      },
    }
    const ctx = await loaderWith({ plugin })
    await ctx.loader.create({ id: 'v', name: 'plugin', config: { label: 'a', rules: { limit: 3 } } } as never)
    await ctx.loader.await()
    const fiber = ctx.loader.resolve('v').fiber!

    await ctx.loader.update('v', { config: { label: 'a', rules: { limit: 7 } } } as never)
    await ctx.loader.await()
    expect(ctx.loader.resolve('v').fiber).toBe(fiber)
    expect(applies).toBe(1)
    expect(seen).toEqual([{ paths: [['rules']], limit: 7 }])

    // An ordinary field falls back to the ordinary remount.
    await ctx.loader.update('v', { config: { label: 'b', rules: { limit: 7 } } } as never)
    await ctx.loader.await()
    expect(applies).toBe(2)
  })
})
