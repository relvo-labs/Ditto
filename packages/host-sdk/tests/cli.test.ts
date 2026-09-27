import { spawnSync } from 'node:child_process'
import { cpSync, existsSync, mkdtempSync, rmSync } from 'node:fs'
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
    const file = join(out, 'ditto.svc.notification-policy-1.0.0.dittopkg')
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
