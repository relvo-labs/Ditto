import { DittoError } from '../errors.ts'
import type { Json } from '../api.ts'

export type HotSwap = 'instant' | 'controlled_handoff' | 'host_restart' | 'session_restart'

/** One entry of HostProjection (docs/contracts/host-protocol.md §4). */
export interface HostEntrySpec {
  entry_id: string
  package: string
  version: string
  module_path: string
  data_dir: string
  config: Json
  disabled: boolean
  provides: string[]
  hot_swap: HotSwap
  health_timeout_ms: number
  cleanup_timeout_ms: number
  /** grant_id → absolute path, for the `files:<grant>` grants this entry holds. Held in memory only. */
  file_grants: Record<string, string>
}

export interface HostProjection {
  role: 'hostd'
  entries: HostEntrySpec[]
}

const hotSwapLevels: readonly HotSwap[] = ['instant', 'controlled_handoff', 'host_restart', 'session_restart']

function fail(message: string): never {
  throw new DittoError('invalid_params', `invalid HostProjection: ${message}`)
}

function string(value: unknown, field: string): string {
  if (typeof value !== 'string' || !value) fail(`${field} must be a non-empty string`)
  return value
}

/** Entry ids become loader ids; the loader reserves ':' as its nesting separator. */
const entryIdPattern = /^[A-Za-z0-9._-]+$/

export function parseProjection(value: unknown): HostProjection {
  if (!value || typeof value !== 'object') fail('target must be an object')
  const target = value as Record<string, unknown>
  if (target['role'] !== 'hostd') fail('role must be "hostd"')
  if (!Array.isArray(target['entries'])) fail('entries must be an array')
  const seen = new Set<string>()
  const entries = target['entries'].map((raw, index): HostEntrySpec => {
    if (!raw || typeof raw !== 'object') fail(`entries[${index}] must be an object`)
    const entry = raw as Record<string, unknown>
    const entryId = string(entry['entry_id'], `entries[${index}].entry_id`)
    if (!entryIdPattern.test(entryId)) fail(`entries[${index}].entry_id has characters the loader cannot key`)
    if (seen.has(entryId)) fail(`duplicate entry_id ${entryId}`)
    seen.add(entryId)
    const hotSwap = entry['hot_swap'] ?? 'controlled_handoff'
    if (!hotSwapLevels.includes(hotSwap as HotSwap)) fail(`entries[${index}].hot_swap is not a known level`)
    const provides = entry['provides'] ?? []
    if (!Array.isArray(provides) || provides.some(item => typeof item !== 'string')) fail(`entries[${index}].provides must be strings`)
    const number = (field: string, fallback: number) => {
      const got = entry[field] ?? fallback
      if (typeof got !== 'number' || !Number.isFinite(got) || got <= 0) fail(`entries[${index}].${field} must be a positive number`)
      return got
    }
    const grants = entry['file_grants'] ?? {}
    if (!grants || typeof grants !== 'object' || Array.isArray(grants) || Object.values(grants).some(path => typeof path !== 'string')) {
      fail(`entries[${index}].file_grants must map grant ids to paths`)
    }
    return {
      entry_id: entryId,
      package: string(entry['package'], `entries[${index}].package`),
      version: string(entry['version'], `entries[${index}].version`),
      module_path: string(entry['module_path'], `entries[${index}].module_path`),
      data_dir: string(entry['data_dir'], `entries[${index}].data_dir`),
      config: (entry['config'] ?? {}) as Json,
      disabled: entry['disabled'] === true,
      provides: provides as string[],
      hot_swap: hotSwap as HotSwap,
      health_timeout_ms: number('health_timeout_ms', 2_000),
      cleanup_timeout_ms: number('cleanup_timeout_ms', 5_000),
      file_grants: { ...(grants as Record<string, string>) },
    }
  })
  return { role: 'hostd', entries }
}

/** Everything except `config` decides whether a new instance is needed. */
export function sameCode(a: HostEntrySpec, b: HostEntrySpec): boolean {
  return a.package === b.package && a.version === b.version && a.module_path === b.module_path && a.data_dir === b.data_dir
    && a.hot_swap === b.hot_swap && a.provides.length === b.provides.length && a.provides.every((id, i) => id === b.provides[i])
}
