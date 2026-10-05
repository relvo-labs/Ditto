import { existsSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { createTestHost, type TestHost } from '@ditto/host-sdk/testing'
import { ArrivalWindow, decide, inQuietHours, type Rules } from '../src/rules.ts'

const root = fileURLToPath(new URL('../', import.meta.url))
const provides = ['desktop.notifications.policy.decide', 'desktop.notifications.policy.get']
const base: Rules = {
  focus: { enabled: false, allow: [] },
  merge: { window_s: 60, threshold: 3 },
  quiet_hours: { enabled: false, start: '22:00', end: '07:00', timezone: 'Asia/Taipei' },
}
const at = (iso: string) => new Date(iso)

describe('rules', () => {
  it('① focus mode lets only the allow-list through', () => {
    const rules = { ...base, focus: { enabled: true, allow: ['org.kde.kate'] } }
    expect(decide(rules, { app_name: 'Kate', app_id: 'org.kde.kate' }, new ArrivalWindow(), new Date())).toMatchObject({ decision: 'show' })
    expect(decide(rules, { app_name: 'Slack' }, new ArrivalWindow(), new Date())).toEqual({ decision: 'silence', rule: 'focus' })
  })

  it('② more than 3 from one app inside 60 s are merged; the window slides', () => {
    const window = new ArrivalWindow()
    const verdicts = [0, 5, 10, 15, 20].map(s => decide(base, { app_name: 'mail', at: `2026-09-27T10:00:${String(s).padStart(2, '0')}Z` }, window, new Date()).decision)
    expect(verdicts).toEqual(['show', 'show', 'show', 'merge', 'merge'])
    expect(decide(base, { app_name: 'other', at: '2026-09-27T10:00:21Z' }, window, new Date()).decision).toBe('show')
    // 61 s after the first four arrivals only the later ones count.
    expect(decide(base, { app_name: 'mail', at: '2026-09-27T10:01:16Z' }, window, new Date())).toMatchObject({ decision: 'show', count_in_window: 2 })
  })

  it('③ quiet hours are evaluated in the configured IANA zone, across midnight', () => {
    const quiet = { ...base.quiet_hours, enabled: true }
    expect(inQuietHours(quiet, at('2026-09-27T15:30:00Z'))).toBe(true)   // 23:30 in Taipei
    expect(inQuietHours(quiet, at('2026-09-27T22:59:00Z'))).toBe(true)   // 06:59 next day
    expect(inQuietHours(quiet, at('2026-09-27T23:00:00Z'))).toBe(false)  // 07:00
    expect(inQuietHours({ ...quiet, timezone: 'Europe/Berlin' }, at('2026-09-27T15:30:00Z'))).toBe(false) // 17:30 in Berlin
    expect(inQuietHours({ ...quiet, timezone: 'Mars/Olympus' }, at('2026-09-27T15:30:00Z'))).toBe(false)
  })

  it('④ critical always passes, even in focus mode during quiet hours past the merge threshold', () => {
    const rules: Rules = { focus: { enabled: true, allow: [] }, merge: { window_s: 60, threshold: 1 }, quiet_hours: { ...base.quiet_hours, enabled: true } }
    const window = new ArrivalWindow()
    for (let i = 0; i < 3; i++) {
      expect(decide(rules, { app_name: 'alarm', urgency: 'critical', at: '2026-09-27T15:30:00Z' }, window, new Date())).toEqual({ decision: 'show', rule: 'critical' })
    }
  })
})

describe('svc-notification-policy in the test host', () => {
  let h: TestHost
  let n = 0
  const change = () => `chg-policy-${++n}`
  const entry = (rules: Partial<Rules> = {}, module = join(root, 'src', 'index.ts')) => h.entry({
    entry_id: 'ent-policy', package: 'ditto.svc.notification-policy', module_path: module, provides,
    config: { rules: { ...base, ...rules } } as never,
  })
  beforeEach(async () => { h = await createTestHost({ packageRoots: [root], pendingWaitMs: 1_000 }) })
  afterEach(async () => { await h.close() })

  it('decides, counts and keeps the last 100 decisions', async () => {
    await h.core.apply(change(), [entry()])
    for (let i = 0; i < 105; i++) await h.core.invoke('desktop.notifications.policy.decide', { app_name: `app-${i % 2}`, at: `2026-09-27T10:00:${String(i % 60).padStart(2, '0')}Z` }, 'core')
    const status = await h.core.invoke('desktop.notifications.policy.get') as { counters: Record<string, number>; recent: Record<string, unknown>[]; rules: unknown }
    // Exactly PolicyGetOutput / PolicyRecord: Core deserialises them strictly.
    expect(Object.keys(status).sort()).toEqual(['counters', 'recent', 'rules'])
    expect(Object.keys(status.counters).sort()).toEqual(['merge', 'show', 'silence'])
    expect(Object.keys(status.recent[0]!).sort()).toEqual(['app_name', 'at', 'decision', 'rule'])
    expect(status.counters.show! + status.counters.merge!).toBe(105)
    expect(status.counters.merge).toBeGreaterThan(0)
    expect(status.recent).toHaveLength(100)
  })

  it('a rule change is committed into the running instance without a remount (volatile config)', async () => {
    await h.core.apply(change(), [entry()])
    const fiber = h.runtime.tx.active.get('ent-policy')!.fiber
    const lease = h.core.bindingOf('desktop.notifications.policy.decide')!.leaseId
    // Exactly PolicyDecideOutput: { decision, rule }.
    expect(await h.core.invoke('desktop.notifications.policy.decide', { app_name: 'Slack', urgency: 'normal', at: new Date().toISOString() })).toEqual({ decision: 'show', rule: 'default' })

    const { committed } = await h.core.apply(change(), [entry({ focus: { enabled: true, allow: ['org.kde.kate'] } })])
    expect(committed!.items[0]).toMatchObject({ status: 'applied' })
    expect(h.runtime.tx.active.get('ent-policy')!.fiber).toBe(fiber)
    expect(h.core.bindingOf('desktop.notifications.policy.decide')!.leaseId).toBe(lease)
    expect(await h.core.invoke('desktop.notifications.policy.decide', { app_name: 'Slack', urgency: 'normal', at: new Date().toISOString() })).toEqual({ decision: 'silence', rule: 'focus' })
    const status = await h.core.invoke('desktop.notifications.policy.get') as { rules: Rules & { revision: number }; counters: Record<string, number> }
    expect(status.rules.focus).toEqual({ enabled: true, allow: ['org.kde.kate'] })
    expect(status.rules.revision).toBe(2)
    // The counters kept running across the rule change: same instance.
    expect(status.counters).toEqual({ show: 1, merge: 0, silence: 1 })
  })

  // The shipped bundle inlines its own Schemastery/Cosmokit copy; volatile references must still be
  // recognised by the host's loader (they are keyed by Symbol.for, not by module identity).
  const bundle = join(root, 'dist', 'index.mjs')
  it.skipIf(!existsSync(bundle))('the built bundle, with its own schema library copy, hot-updates without a remount too', async () => {
    await h.core.apply(change(), [entry({}, bundle)])
    const fiber = h.runtime.tx.active.get('ent-policy')!.fiber
    await h.core.apply(change(), [entry({ focus: { enabled: true, allow: [] } }, bundle)])
    expect(h.runtime.tx.active.get('ent-policy')!.fiber).toBe(fiber)
    expect(await h.core.invoke('desktop.notifications.policy.decide', { app_name: 'Slack', urgency: 'normal', at: new Date().toISOString() })).toEqual({ decision: 'silence', rule: 'focus' })
  })

  it('refuses a malformed request with invalid_params instead of guessing', async () => {
    await h.core.apply(change(), [entry()])
    await expect(h.core.invoke('desktop.notifications.policy.decide', {})).rejects.toMatchObject({ errorName: 'invalid_params' })
  })
})
