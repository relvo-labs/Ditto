import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { youngGeneration } from '../../src/resources.ts'

const flagsFile = join(import.meta.dirname, '..', '..', 'hostd.node-flags')

describe('young generation flags (EX1-04)', () => {
  it('reads the fixed semi-space hostd.node-flags ships', () => {
    const flags = readFileSync(flagsFile, 'utf8').replace(/#.*/g, '').split(/\s+/).filter(Boolean)
    expect(youngGeneration(flags)).toEqual({ min_semi_space_mib: 4, max_semi_space_mib: 4, fixed: true })
  })

  it('says when V8 sizes the young generation itself', () => {
    expect(youngGeneration([])).toEqual({ min_semi_space_mib: null, max_semi_space_mib: null, fixed: false })
    expect(youngGeneration(['--max-semi-space-size=4'])).toMatchObject({ fixed: false })
    expect(youngGeneration(['--min_semi_space_size=2', '--max-semi-space-size=2'])).toMatchObject({ fixed: true, max_semi_space_mib: 2 })
  })
})
