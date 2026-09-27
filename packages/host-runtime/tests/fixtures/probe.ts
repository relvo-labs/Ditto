/**
 * Fixtures report what they did through a process-global probe, so assertions
 * check what actually ran and was cleaned up, not what a component said.
 */
export interface ProbeRecord { event: string; tag: string; at: number; detail?: unknown }

export interface Probe {
  records: ProbeRecord[]
  /** tag → instances whose apply ran and whose cleanup has not finished. */
  live: Map<string, number>
  maxLive: Map<string, number>
  gates: Map<string, Promise<void>>
}

const key = Symbol.for('ditto.test.probe')

export function probe(): Probe {
  const global = globalThis as Record<symbol, Probe | undefined>
  return global[key] ??= { records: [], live: new Map(), maxLive: new Map(), gates: new Map() }
}

export function resetProbe(): void {
  const p = probe()
  p.records.length = 0
  p.live.clear()
  p.maxLive.clear()
  p.gates.clear()
}

export function record(event: string, tag: string, detail?: unknown): void {
  const p = probe()
  p.records.push({ event, tag, at: performance.now(), ...(detail !== undefined ? { detail } : {}) })
  if (event === 'apply') {
    const live = (p.live.get(tag) ?? 0) + 1
    p.live.set(tag, live)
    p.maxLive.set(tag, Math.max(live, p.maxLive.get(tag) ?? 0))
  }
  if (event === 'disposed') p.live.set(tag, (p.live.get(tag) ?? 1) - 1)
}

export function events(event: string, tag?: string): ProbeRecord[] {
  return probe().records.filter(item => item.event === event && (tag === undefined || item.tag === tag))
}

/** Forget what happened so far (e.g. the candidate mounts of a setup change). */
export function clearRecords(): void {
  probe().records.length = 0
}
