import { afterEach, describe, expect, it, vi } from 'vitest'
import { Reclaimer, takeCollector } from '../../src/reclaim.ts'

afterEach(() => { vi.useRealTimers() })

describe('reclaim after disposal (EX1-04)', () => {
  it('coalesces a burst into one collection and never collects inside the caller', () => {
    vi.useFakeTimers()
    let now = 0
    const collect = vi.fn()
    const reclaimer = new Reclaimer(collect, 1_000, () => now)
    for (let i = 0; i < 5; i++) reclaimer.request()
    expect(collect).not.toHaveBeenCalled()
    vi.advanceTimersByTime(0)
    expect(collect).toHaveBeenCalledTimes(1)
  })

  it('collects at most once per interval under steady churn, and the last request is not dropped', () => {
    vi.useFakeTimers()
    let now = 0
    const collect = vi.fn()
    const reclaimer = new Reclaimer(collect, 1_000, () => now)
    reclaimer.request()
    vi.advanceTimersByTime(0)
    expect(collect).toHaveBeenCalledTimes(1)
    now = 100
    reclaimer.request()
    vi.advanceTimersByTime(899)
    expect(collect).toHaveBeenCalledTimes(1)
    now = 1_000
    vi.advanceTimersByTime(1)
    expect(collect).toHaveBeenCalledTimes(2)
    expect(reclaimer.runs).toBe(2)
  })

  it('does nothing without a collector, and takes gc off the global object', () => {
    const reclaimer = new Reclaimer(undefined)
    expect(reclaimer.available).toBe(false)
    reclaimer.request()
    const fake: { gc?: unknown } = { gc: () => {} }
    const gc = takeCollector(fake)
    expect(typeof gc).toBe('function')
    expect(fake.gc).toBeUndefined()
    expect(takeCollector({})).toBeUndefined()
  })
})
