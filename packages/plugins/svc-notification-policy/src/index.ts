import Schema from '@deepseek-ai/schemastery'
import { CapabilityError, defineCapability, defineDittoPlugin, type Context, type Json } from '@ditto/host-sdk'
import { ArrivalWindow, decide, validTimezone, type Decision, type Notification, type Rule, type Rules } from './rules.ts'

/**
 * Notification policy service (plan/03/03 §7). Core's ditto-system asks it,
 * with a 50 ms deadline, what to do with each real org.freedesktop.Notifications
 * call; when it cannot answer, Core shows the notification (a policy is not a
 * permission). Rules are this entry's config and arrive as `.volatile()` values:
 * a rule change from personalisation settings is committed into the running
 * instance without a remount (harness modification #22).
 */
export const Config = Schema.object({
  rules: Schema.object({
    focus: Schema.object({
      enabled: Schema.boolean().default(false),
      allow: Schema.array(Schema.string()).default([]),
    }).default({ enabled: false, allow: [] }),
    merge: Schema.object({
      window_s: Schema.natural().min(1).max(3_600).default(60),
      threshold: Schema.natural().min(1).max(100).default(3),
    }).default({ window_s: 60, threshold: 3 }),
    quiet_hours: Schema.object({
      enabled: Schema.boolean().default(false),
      start: Schema.string().pattern(/^([01]\d|2[0-3]):[0-5]\d$/).default('22:00'),
      end: Schema.string().pattern(/^([01]\d|2[0-3]):[0-5]\d$/).default('07:00'),
      timezone: Schema.string().default('Asia/Taipei'),
    }).default({ enabled: false, start: '22:00', end: '07:00', timezone: 'Asia/Taipei' }),
  }).volatile().default({} as never),
})

/** ditto_protocol::services::PolicyRecord (deserialised strictly by Core). */
interface DecisionRecord { app_name: string; decision: Decision; rule: Rule | null; at: string }

const ringSize = 100

export default defineDittoPlugin<{ rules: { get(): Rules } }>({
  name: 'ditto-svc-notification-policy',
  Config: Config as never,
  apply(ctx: Context, config) {
    const log = ctx.logger('svc-notification-policy')
    const window = new ArrivalWindow()
    const counters: { [key in Decision]: number } = { show: 0, merge: 0, silence: 0 }
    const byRule: { [key in Rule]: number } = { critical: 0, focus: 0, quiet_hours: 0, merge: 0, default: 0 }
    const recent: DecisionRecord[] = []
    const since = new Date().toISOString()
    let rulesRevision = 1

    // Read through the reference on every decision: a volatile update changes it in place.
    const rules = () => config.rules.get()

    ctx.on('loader/volatile-update', paths => {
      rulesRevision += 1
      // A new merge window or threshold starts counting afresh rather than mixing two policies.
      if (paths.some(path => path[0] === 'rules')) window.clear()
    })

    // Wire shapes are ditto_protocol::services::{PolicyDecideInput, PolicyDecideOutput, PolicyGetOutput}.
    // Core parses the decide answer strictly and shows the notification if it cannot, so extra
    // fields here would silently turn every decision into "show".
    ctx.ditto.capabilities.register(defineCapability<Notification, { decision: Decision; rule: Rule | null }>({
      id: 'desktop.notifications.policy.decide',
      version: '1.0.0',
      handler: input => {
        if (!input || typeof input.app_name !== 'string' || !input.app_name) throw new CapabilityError('invalid_params', 'app_name is required')
        const verdict = decide(rules(), input, window, new Date())
        counters[verdict.decision] += 1
        byRule[verdict.rule] += 1
        recent.push({ app_name: input.app_name, decision: verdict.decision, rule: verdict.rule, at: input.at ?? new Date().toISOString() })
        if (recent.length > ringSize) recent.splice(0, recent.length - ringSize)
        log.debug('decided %s for %s by %s (rules revision %d)', verdict.decision, input.app_name, verdict.rule, rulesRevision)
        return { decision: verdict.decision, rule: verdict.rule }
      },
    }))
    ctx.ditto.capabilities.register(defineCapability<Record<string, never>, Json>({
      id: 'desktop.notifications.policy.get',
      version: '1.0.0',
      handler: () => ({
        // The rules as this instance applies them; Core's PolicyGetOutput keeps `rules` opaque.
        rules: { ...rules(), revision: rulesRevision, since, by_rule: { ...byRule }, timezone_valid: validTimezone(rules().quiet_hours.timezone) } as unknown as Json,
        counters: { ...counters },
        recent: recent.map(item => ({ ...item })) as unknown as Json,
      }),
    }))
    // Decisions are not handed over on replacement: counters describe one instance's run.
    ctx.ditto.lifecycle.exportState(() => ({ counters, by_rule: byRule, recent }) as unknown as Json)
    ctx.ditto.lifecycle.importState(state => {
      const previous = state as { counters?: typeof counters; by_rule?: typeof byRule; recent?: DecisionRecord[] }
      Object.assign(counters, previous.counters ?? {})
      Object.assign(byRule, previous.by_rule ?? {})
      recent.unshift(...(previous.recent ?? []).slice(-ringSize))
      if (recent.length > ringSize) recent.splice(0, recent.length - ringSize)
    })
  },
})
