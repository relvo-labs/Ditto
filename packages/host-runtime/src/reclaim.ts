/**
 * Returns a disposed plugin instance's memory promptly (EX1-04, AT-19).
 *
 * Unmounting a Cordis plugin leaves its contexts, closures and hidden classes
 * as garbage, much of it already in V8's old generation. Nothing retains it
 * (heap snapshots after 100 and 400 cycles show no growth in live objects),
 * but V8 collects the old generation only when it reaches a limit, so without
 * this hostd's PSS climbed for hundreds of mount/unmount cycles before
 * levelling off. Chrome tells V8 when a context is disposed; Node has no such
 * call, so hostd asks for one full collection after a mount's disposers have
 * finished: coalesced, and at most once per `minIntervalMs`, so a burst of
 * unmounts costs one collection and a steady churn at most one per interval.
 *
 * The collector is V8's `gc`, exposed by `--expose-gc` in hostd.node-flags and
 * taken off the global object before any plugin loads (takeCollector).
 */
export class Reclaimer {
  private timer: NodeJS.Timeout | undefined
  private last = Number.NEGATIVE_INFINITY
  /** Collections run so far; diagnostics and tests read it. */
  runs = 0

  constructor(
    private readonly collect: (() => void) | undefined,
    private readonly minIntervalMs = 1_000,
    private readonly now: () => number = () => performance.now(),
  ) {}

  get available(): boolean { return this.collect !== undefined }

  /** A mount's disposers finished. Never collects synchronously inside the caller. */
  request(): void {
    if (!this.collect || this.timer) return
    const wait = Math.max(0, this.last + this.minIntervalMs - this.now())
    this.timer = setTimeout(() => {
      this.timer = undefined
      this.last = this.now()
      this.runs += 1
      this.collect!()
    }, wait)
    this.timer.unref()
  }

  stop(): void {
    clearTimeout(this.timer)
    this.timer = undefined
  }
}

/**
 * Take `gc` (from `--expose-gc`) off the global object so plugin code in this
 * process cannot call it. V8 defines it writable but not configurable, so it
 * is overwritten rather than deleted.
 */
export function takeCollector(global: { gc?: unknown } = globalThis as { gc?: unknown }): (() => void) | undefined {
  const gc = typeof global.gc === 'function' ? global.gc as () => void : undefined
  if (gc) global.gc = undefined
  return gc
}
