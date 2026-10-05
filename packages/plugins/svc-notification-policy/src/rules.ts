/** The four rules of plan/03/03 §7, as pure functions so they can be tested without a host. */
export interface Rules {
  focus: { enabled: boolean; allow: string[] }
  merge: { window_s: number; threshold: number }
  quiet_hours: { enabled: boolean; start: string; end: string; timezone: string }
}

export type Urgency = 'low' | 'normal' | 'critical'
export type Decision = 'show' | 'merge' | 'silence'
export type Rule = 'critical' | 'focus' | 'quiet_hours' | 'merge' | 'default'

export interface Notification {
  app_name: string
  app_id?: string
  urgency?: Urgency
  summary?: string
  /** Arrival time from Core (ISO 8601); the plugin's clock is used when absent. */
  at?: string
}

export interface Verdict { decision: Decision; rule: Rule; merge_key?: string; count_in_window?: number }

const hhmm = /^([01]\d|2[0-3]):([0-5]\d)$/

export function validTimezone(zone: string): boolean {
  try {
    new Intl.DateTimeFormat('en-GB', { timeZone: zone })
    return true
  } catch {
    return false
  }
}

/** Minutes since local midnight in an IANA zone. DST is whatever Intl says it is at `at`. */
export function localMinutes(at: Date, zone: string): number {
  const parts = new Intl.DateTimeFormat('en-GB', { timeZone: zone, hour: '2-digit', minute: '2-digit', hourCycle: 'h23' }).formatToParts(at)
  const get = (type: string) => Number(parts.find(part => part.type === type)?.value ?? 0)
  return get('hour') * 60 + get('minute')
}

export function inQuietHours(rules: Rules['quiet_hours'], at: Date): boolean {
  if (!rules.enabled || !hhmm.test(rules.start) || !hhmm.test(rules.end) || !validTimezone(rules.timezone)) return false
  const toMinutes = (text: string) => Number(text.slice(0, 2)) * 60 + Number(text.slice(3))
  const start = toMinutes(rules.start)
  const end = toMinutes(rules.end)
  const now = localMinutes(at, rules.timezone)
  if (start === end) return false
  // A window like 22:00–07:00 wraps past midnight.
  return start < end ? now >= start && now < end : now >= start || now < end
}

/** Sliding per-app arrival window for the merge rule. */
export class ArrivalWindow {
  private readonly arrivals = new Map<string, number[]>()

  record(app: string, atMs: number, windowMs: number): number {
    const kept = (this.arrivals.get(app) ?? []).filter(time => atMs - time < windowMs)
    kept.push(atMs)
    this.arrivals.set(app, kept)
    return kept.length
  }

  clear(): void { this.arrivals.clear() }
}

export function decide(rules: Rules, notification: Notification, window: ArrivalWindow, now: Date): Verdict {
  const app = notification.app_id || notification.app_name
  const at = notification.at ? new Date(notification.at) : now
  const when = Number.isNaN(at.getTime()) ? now : at
  // ④ critical always passes, before any other rule.
  if (notification.urgency === 'critical') return { decision: 'show', rule: 'critical' }
  // ① focus mode: only the allow-list gets through.
  if (rules.focus.enabled && !rules.focus.allow.includes(app) && !rules.focus.allow.includes(notification.app_name)) {
    return { decision: 'silence', rule: 'focus' }
  }
  // ③ quiet hours in the configured IANA zone.
  if (inQuietHours(rules.quiet_hours, when)) return { decision: 'silence', rule: 'quiet_hours' }
  // ② more than `threshold` from one app inside the window are merged.
  const count = window.record(app, when.getTime(), rules.merge.window_s * 1_000)
  if (count > rules.merge.threshold) return { decision: 'merge', rule: 'merge', merge_key: `app:${app}`, count_in_window: count }
  return { decision: 'show', rule: 'default', count_in_window: count }
}
