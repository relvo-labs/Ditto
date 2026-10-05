import { spawnSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import { cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { createTestHost } from '@ditto/host-runtime/testing'
import { bundlePlugin } from '../scripts/bundle-plugin.mjs'
import type { JsonSchema } from './manifest/json-schema.ts'
import { validateManifest, type ManifestIssue, type ManifestValidation } from './manifest/rules.ts'

export interface PackageValidation extends ManifestValidation {
  manifest?: Record<string, unknown>
  /** Capabilities the entry registered when mounted as a candidate in a test host. */
  registered?: string[]
}

/** Walk up from `start` looking for the Rust-generated `schema/manifest.json`. */
export function findManifestSchema(start: string): string | undefined {
  let dir = resolve(start)
  while (true) {
    const candidate = join(dir, 'schema', 'manifest.json')
    if (existsSync(candidate)) return candidate
    const parent = dirname(dir)
    if (parent === dir) return undefined
    dir = parent
  }
}

function provided(manifest: Record<string, unknown>): string[] {
  return ((manifest['provides'] as { capability?: unknown }[] | undefined) ?? [])
    .map(item => item?.capability).filter((id): id is string => typeof id === 'string')
}

/**
 * `ditto-plugin validate`: manifest rules, files the manifest points at, and —
 * for Cordis packages — that every provided capability has a handler, found by
 * mounting the entry as a candidate in the in-process test host.
 */
export async function validatePackage(dir: string, options: { schema?: JsonSchema; checkHandlers?: boolean } = {}): Promise<PackageValidation> {
  const path = join(dir, 'manifest.json')
  let manifest: Record<string, unknown>
  try {
    manifest = JSON.parse(readFileSync(path, 'utf8')) as Record<string, unknown>
  } catch (error) {
    return { ok: false, errors: [{ path: '/', code: 'schema_invalid', message: `cannot read manifest.json: ${(error as Error).message}` }], warnings: [] }
  }
  const result: PackageValidation = { ...validateManifest(manifest, options.schema ? { schema: options.schema } : {}), manifest }
  const fail = (issue: ManifestIssue) => { result.errors.push(issue); result.ok = false }
  const host = manifest['host_kind']
  const entryKey = host === 'cordis' ? 'entry' : host === 'qml' ? 'qml_entry' : undefined
  const entry = entryKey ? manifest[entryKey] : undefined
  if (entryKey && typeof entry === 'string' && !existsSync(join(dir, entry))) {
    fail({ path: `/${entryKey}`, code: 'package_missing', message: `${entry} does not exist (run ditto-plugin pack or build first)` })
  }
  if (host === 'cordis' && options.checkHandlers !== false && typeof entry === 'string' && existsSync(join(dir, entry)) && result.errors.length === 0) {
    const registered = await registeredCapabilities(dir, join(dir, entry), manifest)
    result.registered = registered
    for (const id of provided(manifest)) {
      if (!registered.includes(id)) fail({ path: '/provides', code: 'handler_missing', message: `${id} is declared but the plugin registered no handler for it` })
    }
  }
  return result
}

async function registeredCapabilities(dir: string, modulePath: string, manifest: Record<string, unknown>): Promise<string[]> {
  const host = await createTestHost({ packageRoots: [dir], strategy: 'isolate_rebuild', pendingWaitMs: 1_000 })
  try {
    const spec = host.entry({
      entry_id: 'ent-validate', module_path: resolve(modulePath), package: String(manifest['id']), version: String(manifest['version']),
      provides: provided(manifest), config: defaultsOf(manifest),
    })
    const prepared = await host.core.prepare('chg-validate', [spec])
    const candidate = host.runtime.tx.instancesOf('ent-validate')[0]
    const ids = candidate ? [...candidate.registrations.keys()] : []
    await host.core.abort('chg-validate')
    if (prepared.items[0]?.status !== 'ready') throw new Error(`entry did not start in the test host: ${prepared.items[0]?.reason}`)
    return ids
  } finally {
    await host.close()
  }
}

function defaultsOf(manifest: Record<string, unknown>): Record<string, never> {
  const properties = ((manifest['config_schema'] as { properties?: Record<string, { default?: unknown }> } | undefined)?.properties) ?? {}
  return Object.fromEntries(Object.entries(properties).filter(([, sub]) => 'default' in sub).map(([key, sub]) => [key, sub.default])) as Record<string, never>
}

export interface PackResult { file: string; sha256: string; bytes: number }

/**
 * `ditto-plugin pack`: bundle (Cordis) or collect qml/ (QML), then tar+zstd
 * manifest.json plus that one directory. The sha256 is over the whole
 * .dittopkg file (manifest.md). Entries are sorted and timestamps zeroed so
 * the same sources give the same hash.
 */
export async function packPackage(dir: string, options: { out?: string; schema?: JsonSchema; checkHandlers?: boolean } = {}): Promise<PackResult> {
  const manifest = JSON.parse(readFileSync(join(dir, 'manifest.json'), 'utf8')) as Record<string, unknown>
  if (manifest['host_kind'] === 'cordis') await bundlePlugin(dir)
  const validation = await validatePackage(dir, { ...(options.schema ? { schema: options.schema } : {}), checkHandlers: options.checkHandlers !== false })
  if (!validation.ok) {
    throw new Error(`manifest is not valid:\n${validation.errors.map(issue => `  ${issue.path} [${issue.code}] ${issue.message}`).join('\n')}`)
  }
  const payload = manifest['host_kind'] === 'cordis' ? 'dist' : manifest['host_kind'] === 'qml' ? 'qml' : undefined
  if (!payload) throw new Error('only cordis and qml packages are packed as .dittopkg')
  const stage = mkdtempSync(join(tmpdir(), 'ditto-pack-'))
  try {
    cpSync(join(dir, 'manifest.json'), join(stage, 'manifest.json'))
    if (payload === 'dist') {
      mkdirSync(join(stage, 'dist'), { recursive: true })
      cpSync(join(dir, String(manifest['entry'])), join(stage, String(manifest['entry'])))
    } else {
      cpSync(join(dir, 'qml'), join(stage, 'qml'), { recursive: true })
    }
    // `--out` may name the file or a directory; a directory gets `<id>-<version>.dittopkg`.
    const name = `${manifest['id']}-${manifest['version']}.dittopkg`
    const wanted = options.out ? resolve(options.out) : join(dir, name)
    const isDir = options.out !== undefined && (options.out.endsWith('/') || (existsSync(wanted) && statSync(wanted).isDirectory()))
    const out = isDir ? join(wanted, name) : wanted
    mkdirSync(dirname(out), { recursive: true })
    const tar = spawnSync('tar', [
      '--sort=name', '--mtime=@0', '--owner=0', '--group=0', '--numeric-owner', '--mode=a+rX,u+w,go-w',
      '--zstd', '-cf', out, '-C', stage, 'manifest.json', payload,
    ], { encoding: 'utf8', env: { ...process.env, ZSTD_CLEVEL: '19' } })
    if (tar.status !== 0) throw new Error(`tar --zstd failed: ${tar.stderr}`)
    const bytes = readFileSync(out)
    return { file: out, sha256: createHash('sha256').update(bytes).digest('hex'), bytes: bytes.length }
  } finally {
    rmSync(stage, { recursive: true, force: true })
  }
}
