import type { FaultPoint } from './fault.ts'

/**
 * `DITTO_HOST_FAULT=<point>:<action>[:<n>][,...]`
 *   action: throw | hang | exit | kill | delay=<ms>
 *   n:      fire only on the n-th hit of that point (1-based); omitted = every hit
 * Parsed on every hit so a test can change it between phases of one process.
 */
interface Rule { point: string; action: string; nth?: number }

const hits = new Map<string, number>()

function parse(spec: string | undefined): Rule[] {
  if (!spec) return []
  return spec.split(',').filter(Boolean).map(item => {
    const [point = '', action = '', nth] = item.split(':')
    return { point, action, ...(nth ? { nth: Number(nth) } : {}) }
  })
}

export async function faultPoint(point: FaultPoint): Promise<void> {
  const count = (hits.get(point) ?? 0) + 1
  hits.set(point, count)
  for (const rule of parse(process.env['DITTO_HOST_FAULT'])) {
    if (rule.point !== point) continue
    if (rule.nth !== undefined && rule.nth !== count) continue
    process.stderr.write(JSON.stringify({ ts: new Date().toISOString(), level: 'warn', msg: 'fault injected', point, action: rule.action, hit: count }) + '\n')
    if (rule.action === 'throw') throw new Error(`fault injected at ${point}`)
    if (rule.action === 'hang') await new Promise(() => {})
    if (rule.action === 'exit') process.exit(70)
    if (rule.action === 'kill') process.kill(process.pid, 'SIGKILL')
    if (rule.action.startsWith('delay=')) await new Promise(resolve => setTimeout(resolve, Number(rule.action.slice(6))))
  }
}

/** Tests reset hit counters between cases. */
export function resetFaultHits(): void { hits.clear() }
