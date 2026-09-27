import { unsupportedKeywords, validateJsonSchema, type JsonSchema } from './json-schema.ts'
import { parseRange, parseVersion } from './semver.ts'

/**
 * The manifest rules of docs/contracts/manifest.md, checked on the author's
 * side. Core re-checks everything in preflight; this only catches mistakes
 * before a package is built. Issue codes reuse the preflight vocabulary
 * (protocol-0.2 §8.3) where one fits.
 */
export interface ManifestIssue {
  path: string
  code: string
  message: string
}

export interface ManifestValidation {
  ok: boolean
  errors: ManifestIssue[]
  warnings: ManifestIssue[]
}

export interface ValidateOptions {
  /** `schema/manifest.json` generated from `ditto_protocol::manifest::Manifest`, once it exists. */
  schema?: JsonSchema
  /** Versions the package must run on (the frozen Ditto toolchain). */
  hostProtocolVersion?: string
  nodeVersion?: string
}

const idPattern = /^[a-z0-9]+(\.[a-z0-9_-]+)+$/
const slotPattern = /^[a-z]+(\.[a-z_]+)+$/
const eventPattern = /^[a-z0-9_-]+(\/[a-z0-9_-]+)+$/
const pluginKinds = ['service', 'qml_provider', 'declarative_bundle'] as const
const hostFor: Record<string, string> = { service: 'cordis', qml_provider: 'qml', declarative_bundle: 'core_builtin' }
const hotSwapLevels = ['instant', 'controlled_handoff', 'host_restart', 'session_restart']
const scopes = new Set([
  'desktop.read', 'desktop.config', 'desktop.windows.read', 'desktop.windows.control', 'desktop.rescue', 'plugins.manage',
  'permissions.manage', 'session.power', 'session.lock', 'notifications.read', 'tasks.read', 'tasks.write', 'apps.launch',
  'network', 'process.exec', 'clipboard', 'screenshot',
])
/** Provisional: Core owns the reserved list (rescue, lock); replace with the catalog's once published. */
export const reservedChords = new Set(['Super+L', 'Ctrl+Alt+Delete', 'Ctrl+Alt+Backspace', 'Super+Shift+Escape'])
/** Policy caps for service plugins (manifest.md `resource_budget`). */
export const serviceBudget = { memory_mib: 64, cpu_percent: 10 }
const known = new Set([
  'manifest_version', 'id', 'version', 'name', 'author', 'license', 'source', 'description', 'plugin_kind', 'host_kind',
  'trust_level', 'runtime', 'platform', 'required_protocol_version', 'slots', 'provides', 'requires', 'optional',
  'conflicts', 'entry', 'qml_entry', 'config_schema', 'data_schema', 'commands', 'shortcuts', 'events', 'permissions',
  'hot_swap', 'health', 'cleanup', 'migrations', 'activation_events', 'idle_policy', 'resource_budget', 'rescue',
])

type Obj = Record<string, unknown>
const isObject = (value: unknown): value is Obj => typeof value === 'object' && value !== null && !Array.isArray(value)

export function validateManifest(manifest: unknown, options: ValidateOptions = {}): ManifestValidation {
  const errors: ManifestIssue[] = []
  const warnings: ManifestIssue[] = []
  const error = (path: string, code: string, message: string) => errors.push({ path, code, message })
  const warn = (path: string, code: string, message: string) => warnings.push({ path, code, message })
  const protocol = options.hostProtocolVersion ?? '0.2.0'
  const node = options.nodeVersion ?? '22.23.2'

  if (options.schema !== undefined) {
    for (const issue of validateJsonSchema(options.schema, manifest)) error(issue.path, 'schema_invalid', issue.message)
  }
  if (!isObject(manifest)) {
    error('/', 'schema_invalid', 'manifest must be a JSON object')
    return { ok: false, errors, warnings }
  }
  const m = manifest
  const str = (key: string, required = true): string | undefined => {
    const value = m[key]
    if (value === undefined) { if (required) error(`/${key}`, 'schema_invalid', 'is required'); return undefined }
    if (typeof value !== 'string' || !value) { error(`/${key}`, 'schema_invalid', 'must be a non-empty string'); return undefined }
    return value
  }
  const array = (key: string, required = true): unknown[] | undefined => {
    const value = m[key]
    if (value === undefined) { if (required) error(`/${key}`, 'schema_invalid', 'is required'); return undefined }
    if (!Array.isArray(value)) { error(`/${key}`, 'schema_invalid', 'must be an array'); return undefined }
    return value
  }
  const range = (path: string, value: unknown, code = 'schema_invalid') => {
    if (typeof value !== 'string' || !parseRange(value)) { error(path, code, 'must be a semver range'); return undefined }
    return parseRange(value)!
  }

  for (const key of Object.keys(m)) if (!known.has(key)) warn(`/${key}`, 'unknown_field', 'is not a manifest field; Core ignores it')

  if (m['manifest_version'] !== 1) error('/manifest_version', 'schema_invalid', 'must be 1')
  const id = str('id')
  if (id && !idPattern.test(id)) error('/id', 'schema_invalid', 'must be reverse-domain style, e.g. ditto.dock.pill')
  const version = str('version')
  if (version && !parseVersion(version)) error('/version', 'schema_invalid', 'must be semver')

  // ditto_protocol::manifest::Manifest types `name` as a locale map (manifest.md also allows a plain
  // string; the Rust type is the authority, so a string is refused here).
  const name = m['name']
  if (name === undefined) error('/name', 'schema_invalid', 'is required: { "zh-TW": "…", "en": "…" }')
  else if (!isObject(name) || !Object.keys(name).length || !Object.values(name).every(v => typeof v === 'string')) {
    error('/name', 'schema_invalid', 'must be a { locale: text } object')
  }
  str('author')
  str('license')
  str('source')
  if (m['description'] !== undefined && typeof m['description'] !== 'string' && !isObject(m['description'])) {
    error('/description', 'schema_invalid', 'must be a string or a { locale: text } object')
  }

  const kind = str('plugin_kind')
  const host = str('host_kind')
  if (kind && !(pluginKinds as readonly string[]).includes(kind)) error('/plugin_kind', 'schema_invalid', `must be one of ${pluginKinds.join(', ')}`)
  if (host && !['cordis', 'qml', 'core_builtin'].includes(host)) error('/host_kind', 'schema_invalid', 'must be cordis, qml or core_builtin')
  if (kind && host && hostFor[kind] && hostFor[kind] !== host) error('/host_kind', 'schema_invalid', `${kind} must use host_kind ${hostFor[kind]}`)

  const trust = str('trust_level')
  if (trust && !['trusted', 'community', 'untrusted'].includes(trust)) error('/trust_level', 'schema_invalid', 'must be trusted, community or untrusted')
  if (trust && (trust !== 'trusted' || m['source'] !== 'builtin')) {
    warn('/trust_level', 'precondition_failed', 'G1 only accepts trusted packages with source "builtin"; Core will refuse this one in preflight')
  }

  const runtime = m['runtime']
  if (!isObject(runtime)) error('/runtime', 'schema_invalid', 'is required: { "node": "<range>" } or { "qt": "<range>" }')
  else if (host === 'cordis') {
    const nodeRange = range('/runtime/node', runtime['node'])
    if (nodeRange && !nodeRange(node)) error('/runtime/node', 'protocol_incompatible', `does not include the Ditto Node runtime ${node}`)
  } else if (host === 'qml') {
    range('/runtime/qt', runtime['qt'])
  }
  const platform = array('platform')
  if (platform && (!platform.length || platform.some(item => typeof item !== 'string'))) error('/platform', 'schema_invalid', 'must be a non-empty list of platform ids')
  else if (platform && !platform.includes('linux-x86_64')) warn('/platform', 'precondition_failed', 'does not list linux-x86_64, the only G1 platform')
  const protocolRange = range('/required_protocol_version', m['required_protocol_version'])
  if (protocolRange && !protocolRange(protocol)) error('/required_protocol_version', 'protocol_incompatible', `does not accept protocol ${protocol}`)

  const slots = array('slots')
  slots?.forEach((slot, i) => { if (typeof slot !== 'string' || !slotPattern.test(slot)) error(`/slots/${i}`, 'schema_invalid', 'must be a slot id such as ui.dock') })

  const provides = array('provides') ?? []
  const provided: string[] = []
  provides.forEach((item, i) => {
    if (!isObject(item) || (typeof item['capability'] !== 'string') === (typeof item['service'] !== 'string')) {
      error(`/provides/${i}`, 'schema_invalid', 'must be { "capability": id } or { "service": name }')
      return
    }
    const capability = item['capability']
    if (typeof capability === 'string') {
      provided.push(capability)
      if (capability.startsWith('plugin.')) {
        if (id && !capability.startsWith(`plugin.${id}.`)) error(`/provides/${i}`, 'schema_invalid', `plugin capabilities must live under plugin.${id}.*`)
      } else if (!capability.startsWith('desktop.')) {
        error(`/provides/${i}`, 'schema_invalid', 'capabilities are desktop.* (static catalog) or plugin.<id>.*')
      }
    }
  })
  if (provided.length !== new Set(provided).size) error('/provides', 'single_provider_violation', 'declares the same capability twice')
  if (host === 'cordis' && provided.length === 0) warn('/provides', 'recorded', 'a service plugin that provides no capability is invisible outside hostd')

  for (const key of ['requires', 'optional']) {
    array(key)?.forEach((item, i) => {
      const path = `/${key}/${i}`
      if (!isObject(item)) return error(path, 'schema_invalid', 'must be an object')
      if (typeof item['package'] === 'string') {
        if (!idPattern.test(item['package'])) error(`${path}/package`, 'schema_invalid', 'must be a package id')
        if (item['version'] !== undefined) range(`${path}/version`, item['version'])
      } else if (typeof item['capability'] !== 'string' && typeof item['service'] !== 'string') {
        error(path, 'schema_invalid', 'must name a package, capability or service')
      }
    })
  }
  array('conflicts')?.forEach((item, i) => {
    if (typeof item !== 'string' || !idPattern.test(item)) error(`/conflicts/${i}`, 'schema_invalid', 'must be a package id')
    else if (item === id) error(`/conflicts/${i}`, 'declared_conflict', 'a package cannot conflict with itself')
  })

  const relative = (key: string, suffix: RegExp) => {
    const value = str(key)
    if (!value) return
    if (value.startsWith('/') || value.split('/').includes('..')) error(`/${key}`, 'schema_invalid', 'must be relative to the package root')
    if (!suffix.test(value)) error(`/${key}`, 'schema_invalid', `must end in ${suffix.source.replace(/\\|\$/g, '')}`)
  }
  if (host === 'cordis') relative('entry', /\.mjs$/)
  if (host === 'qml') relative('qml_entry', /\.qml$/)

  const configSchema = m['config_schema']
  if (!isObject(configSchema)) error('/config_schema', 'schema_invalid', 'is required (use { "type": "object", "properties": {} } for none)')
  else {
    if (configSchema['type'] !== 'object') error('/config_schema/type', 'schema_invalid', 'the top level must be an object schema')
    for (const issue of unsupportedKeywords(configSchema)) error(issue.path, 'schema_invalid', issue.message)
    const defaults = Object.fromEntries(Object.entries((configSchema['properties'] ?? {}) as Obj)
      .filter(([, sub]) => isObject(sub) && 'default' in sub).map(([key, sub]) => [key, (sub as Obj)['default']]))
    for (const issue of validateJsonSchema({ ...configSchema, required: [] }, defaults)) error(`/config_schema${issue.path}`, 'schema_invalid', `default ${issue.message}`)
  }
  if (m['data_schema'] !== undefined && !isObject(m['data_schema'])) error('/data_schema', 'schema_invalid', 'must be a JSON Schema object')

  const commands = array('commands') ?? []
  const commandIds = new Set<string>()
  commands.forEach((item, i) => {
    if (!isObject(item) || typeof item['id'] !== 'string' || typeof item['title_key'] !== 'string') return error(`/commands/${i}`, 'schema_invalid', 'needs id and title_key')
    if (commandIds.has(item['id'])) error(`/commands/${i}`, 'command_conflict', `command ${item['id']} is declared twice`)
    commandIds.add(item['id'])
  })
  const chords = new Set<string>()
  array('shortcuts')?.forEach((item, i) => {
    if (!isObject(item) || typeof item['chord'] !== 'string' || typeof item['command'] !== 'string') return error(`/shortcuts/${i}`, 'schema_invalid', 'needs chord and command')
    if (reservedChords.has(item['chord'])) error(`/shortcuts/${i}`, 'shortcut_conflict', `${item['chord']} is reserved by Core`)
    if (chords.has(item['chord'])) error(`/shortcuts/${i}`, 'shortcut_conflict', `${item['chord']} is bound twice`)
    chords.add(item['chord'])
    if (!commandIds.has(item['command'])) error(`/shortcuts/${i}/command`, 'schema_invalid', `${item['command']} is not one of this package's commands`)
  })
  const eventNames = new Set<string>()
  array('events')?.forEach((item, i) => {
    const path = `/events/${i}`
    if (!isObject(item) || typeof item['name'] !== 'string') return error(path, 'schema_invalid', 'needs a name')
    if (!eventPattern.test(item['name'])) error(`${path}/name`, 'schema_invalid', 'must look like tasks/changed')
    if (eventNames.has(item['name'])) error(`${path}/name`, 'schema_invalid', 'is declared twice')
    eventNames.add(item['name'])
    if (!isObject(item['schema'])) error(`${path}/schema`, 'schema_invalid', 'cross-process events must carry a schema')
    if (item['coalesce'] !== 'none' && item['coalesce'] !== 'latest') error(`${path}/coalesce`, 'schema_invalid', 'must be none or latest')
  })
  array('permissions')?.forEach((item, i) => {
    if (typeof item !== 'string' || !(scopes.has(item) || /^files:(\*|[A-Za-z0-9_.-]+)$/.test(item))) {
      error(`/permissions/${i}`, 'schema_invalid', 'is not a resource scope of protocol 0.2 §7')
    }
    if (item === 'core') error(`/permissions/${i}`, 'permission_required', 'the core scope cannot be requested')
  })

  const hotSwap = str('hot_swap')
  if (hotSwap && !hotSwapLevels.includes(hotSwap)) error('/hot_swap', 'schema_invalid', `must be one of ${hotSwapLevels.join(', ')}`)
  for (const key of ['health', 'cleanup']) {
    const value = m[key]
    if (!isObject(value) || !Number.isInteger(value['timeout_ms']) || (value['timeout_ms'] as number) <= 0) {
      error(`/${key}/timeout_ms`, 'schema_invalid', 'must be a positive integer')
    }
  }
  if (m['migrations'] !== undefined && !Array.isArray(m['migrations'])) error('/migrations', 'schema_invalid', 'must be an array')
  if (m['activation_events'] !== undefined && (!Array.isArray(m['activation_events']) || m['activation_events'].some(e => typeof e !== 'string'))) {
    error('/activation_events', 'schema_invalid', 'must be a list of strings')
  }
  const idle = str('idle_policy')
  if (idle && idle !== 'resident' && idle !== 'on_demand') error('/idle_policy', 'schema_invalid', 'must be resident or on_demand')

  const budget = m['resource_budget']
  if (budget !== undefined) {
    if (!isObject(budget) || typeof budget['memory_mib'] !== 'number' || typeof budget['cpu_percent'] !== 'number') {
      error('/resource_budget', 'schema_invalid', 'needs memory_mib and cpu_percent')
    } else if (kind === 'service' && (budget['memory_mib'] > serviceBudget.memory_mib || budget['cpu_percent'] > serviceBudget.cpu_percent)) {
      error('/resource_budget', 'budget_exceeded', `service plugins are capped at ${serviceBudget.memory_mib} MiB and ${serviceBudget.cpu_percent}%`)
    }
  }
  const rescue = m['rescue']
  if (rescue !== undefined && (!isObject(rescue) || typeof rescue['disable_safe'] !== 'boolean')) error('/rescue', 'schema_invalid', 'must be { "disable_safe": boolean }')

  return { ok: errors.length === 0, errors, warnings }
}
