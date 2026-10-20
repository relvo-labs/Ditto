import { spawnSync } from 'node:child_process'
import { cpSync, existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { afterAll, beforeAll, describe, expect, it } from 'vitest'

/**
 * The built CLI, run the way scripts and authors run it: from another working
 * directory, through bin/ditto-plugin. It must not resolve anything relative
 * to its own dist/ (the vendored-licence read did, and crashed at start-up).
 */
const sdk = fileURLToPath(new URL('../', import.meta.url))
const cli = join(sdk, 'bin', 'ditto-plugin')
const packages = join(sdk, '..')
const scratch = mkdtempSync(join(tmpdir(), 'ditto-cli-'))
const run = (...args: string[]) => spawnSync(cli, args, { cwd: scratch, encoding: 'utf8', env: { ...process.env } })

beforeAll(() => {
  // Always test the bundle built from this tree.
  const built = spawnSync(process.execPath, [join(sdk, 'scripts', 'build.mjs')], { encoding: 'utf8' })
  if (built.status !== 0) throw new Error(built.stderr)
}, 60_000)
afterAll(() => rmSync(scratch, { recursive: true, force: true }))

describe('ditto-plugin (built CLI)', () => {
  describe.each(['schema', 'schema-free'])('builtin panel budget (%s)', mode => {
    const source = join(packages, '..', 'shell/providers/panel_top')
    const dir = mode === 'schema' ? source : join(scratch, 'panel')

    it('validates and packs the existing memory-only panel budget', () => {
      if (mode === 'schema-free') cpSync(source, dir, { recursive: true })
      const result = run('validate', dir)
      expect(result.stderr).toBe('')
      expect(result.status).toBe(0)
      expect(result.stdout).toContain(mode === 'schema' ? '(schema ' : '(TypeScript rules only;')
      const file = join(scratch, `panel-${mode}.dittopkg`)
      const packed = run('pack', dir, '--out', file)
      expect(packed.stderr).toBe('')
      expect(packed.status).toBe(0)
      const extracted = spawnSync('tar', ['--zstd', '-xOf', file, 'manifest.json'], { encoding: 'utf8' })
      expect(extracted.status).toBe(0)
      expect(JSON.parse(extracted.stdout)).toEqual(JSON.parse(readFileSync(join(source, 'manifest.json'), 'utf8')))
      expect(JSON.parse(extracted.stdout).resource_budget).toEqual({ memory_mib: 8 })
    })

    it('rejects an overflowing budget through validate and pack', () => {
      const bad = join(scratch, `bad-panel-${mode}`)
      cpSync(source, bad, { recursive: true })
      const manifest = JSON.parse(readFileSync(join(bad, 'manifest.json'), 'utf8'))
      manifest.resource_budget = { memory_mib: 4_294_967_296, cpu_percent: 2 }
      writeFileSync(join(bad, 'manifest.json'), JSON.stringify(manifest))
      const args = mode === 'schema' ? ['--schema', join(packages, '..', 'schema/manifest.json')] : []
      for (const command of ['validate', 'pack']) {
        const result = run(command, bad, ...args, '--out', join(scratch, `bad-${mode}.dittopkg`))
        expect(result.status).toBe(1)
        expect(result.stderr).toContain('/resource_budget/memory_mib [schema_invalid]')
      }
      expect(existsSync(join(scratch, `bad-${mode}.dittopkg`))).toBe(false)
    })
  })

  it('validates a package from an unrelated working directory', () => {
    const result = run('validate', join(packages, 'plugins', 'svc-tasks'))
    expect(result.stderr).toBe('')
    expect(result.status).toBe(0)
    expect(result.stdout).toMatch(/^ok /)
  })

  it('packs into a directory as <id>-<version>.dittopkg, bundling vendored code with its licence notice', () => {
    const dir = join(scratch, 'policy')
    cpSync(join(packages, 'plugins', 'svc-notification-policy'), dir, { recursive: true, filter: source => !/\/(dist|node_modules)(\/|$)/.test(source) })
    const out = join(scratch, 'out')
    const result = run('pack', dir, '--out', `${out}/`)
    expect(result.status).toBe(0)
    const file = join(out, 'ditto.svc.notification-policy-1.1.0.dittopkg')
    expect(existsSync(file)).toBe(true)
    expect(result.stdout).toMatch(/^sha256:[0-9a-f]{64}  /)
    const bundle = spawnSync('tar', ['--zstd', '-xOf', file, 'dist/index.mjs'], { encoding: 'utf8' }).stdout
    expect(bundle.startsWith('/*!\n * Includes vendored Cordis')).toBe(true)
  })

  it('fails with a usage message, not a crash, on bad arguments', () => {
    const result = run('frobnicate')
    expect(result.status).toBe(2)
    expect(result.stderr).toMatch(/^usage: ditto-plugin/)
  })
})
