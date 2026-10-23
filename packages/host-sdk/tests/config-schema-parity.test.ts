import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { describe, expect, it } from 'vitest'
import * as manifestApi from '../src/manifest/index.ts'
import { validateJsonSchema, validateManifest, type JsonSchema } from '../src/manifest/index.ts'

/**
 * #161: the SDK and Core judge config_schema the same way. Both sides read
 * tests/config-schema/parity.json; the Rust half is in
 * crates/ditto-protocol/src/config_schema.rs.
 */
const root = fileURLToPath(new URL('../../../', import.meta.url))
type Case = { name: string, schema: JsonSchema, value: unknown, violations?: string[], unsupported?: string }
// JSON.parse keeps "__proto__" as an own key, which is the point of some cases.
const cases = (JSON.parse(readFileSync(join(root, 'tests/config-schema/parity.json'), 'utf8')) as { cases: Case[] }).cases
const counter = JSON.parse(readFileSync(join(root, 'packages/host-sdk/examples/counter/manifest.json'), 'utf8')) as Record<string, unknown>
const configSchemaIssues = (manifestApi as Record<string, unknown>)['configSchemaIssues'] as
  ((schema: unknown, path?: string) => { path: string, message: string }[]) | undefined

describe('config_schema parity with Core (tests/config-schema/parity.json)', () => {
  it('has the shared cases', () => {
    expect(cases.length).toBeGreaterThan(15)
    expect(typeof configSchemaIssues).toBe('function')
  })

  it.each(cases.flatMap((c, index) => c.violations === undefined ? [] : [[c.name, index] as const]))(
    'judges a config as Core does: %s',
    (_name, index) => {
      const c = cases[index]!
      const pointers = validateJsonSchema(c.schema, c.value).map(issue => issue.path === '/' ? '' : issue.path)
      expect(pointers).toEqual(c.violations)
    },
  )

  it.each(cases.map((c, index) => [c.name, index] as const))('supports the same schemas as Core: %s', (_name, index) => {
    const c = cases[index]!
    const support = configSchemaIssues!(c.schema, '')
    if (c.unsupported === undefined) expect(support).toEqual([])
    else expect(support.map(issue => issue.path)[0]).toBe(c.unsupported)
  })

  it.each(cases.filter(c => c.unsupported !== undefined).map(c => [c.name, c] as const))(
    'manifest validation refuses %s, with or without defaults',
    (_name, c) => {
      const errors = validateManifest({ ...counter, config_schema: c.schema }).errors
      expect(errors.some(e => e.code === 'schema_invalid' && e.path === `/config_schema${c.unsupported}`), JSON.stringify(errors)).toBe(true)
    },
  )
})
