import { configSchemaIssues, validateJsonSchema, type JsonSchema } from './json-schema.ts'
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
  'hot_swap', 'health', 'cleanup', 'migrations', 'activation_events', 'idle_policy', 'resource_budget', 'rescue', 'settings_page',
])

type Obj = Record<string, unknown>
const isObject = (value: unknown): value is Obj => typeof value === 'object' && value !== null && !Array.isArray(value)

export function validateManifest(manifest: unknown, options: ValidateOptions = {}): ManifestValidation {
  const errors: ManifestIssue[] = []
  const warnings: ManifestIssue[] = []
  const error = (path: string, code: string, message: string) => errors.push({ path, code, message })
  const warn = (path: string, code: string, message: string) => warnings.push({ path, code, message })
  const protocol = options.hostProtocolVersion ?? '0.3.0'
  const node = options.nodeVersion ?? '22.23.2'

  if (options.schema !== undefined) {
    for (const issue of validateJsonSchema(options.schema, manifest)) error(issue.path, 'schema_invalid', issue.message)
  }
  if (!isObject(manifest)) {
    error('/', 'schema_invalid', 'manifest must be a JSON object')
    return { ok: false, errors, warnings }
  }
  const declarative = manifest['plugin_kind'] === 'declarative_bundle' && manifest['host_kind'] === 'core_builtin'
  const m = declarative ? { ...manifest } : manifest
  if (declarative) {
    // Manifest's serde defaults, for declarative bundles that execute neither Node nor QML.
    // Default only absent fields in a local view; explicit null/malformed values still get checked.
    const defaults: Obj = {
      runtime: {}, platform: [], slots: [], provides: [], requires: [], optional: [], conflicts: [],
      config_schema: { type: 'object' }, commands: [], shortcuts: [], events: [], permissions: [],
      migrations: [], activation_events: [],
    }
    for (const [key, value] of Object.entries(defaults)) if (m[key] === undefined) m[key] = value
  }
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
  else {
    if (host === 'cordis' || (declarative && runtime['node'] !== undefined && runtime['node'] !== null)) {
      const nodeRange = range('/runtime/node', runtime['node'])
      if (nodeRange && !nodeRange(node)) error('/runtime/node', 'protocol_incompatible', `does not include the Ditto Node runtime ${node}`)
    }
    if (host === 'qml' || (declarative && runtime['qt'] !== undefined && runtime['qt'] !== null)) {
      range('/runtime/qt', runtime['qt'])
    }
    if (declarative) for (const key of Object.keys(runtime)) {
      if (key !== 'node' && key !== 'qt') error(`/runtime/${key}`, 'schema_invalid', 'is not a runtime requirement field')
    }
  }
  const platform = array('platform')
  if (platform && ((!declarative && !platform.length) || platform.some(item => typeof item !== 'string'))) error('/platform', 'schema_invalid', declarative ? 'must be a list of platform ids' : 'must be a non-empty list of platform ids')
  else if (platform && platform.length > 0 && !platform.includes('linux-x86_64')) warn('/platform', 'precondition_failed', 'does not list linux-x86_64, the only G1 platform')
  const protocolRange = range('/required_protocol_version', m['required_protocol_version'])
  if (protocolRange && !protocolRange(protocol)) error('/required_protocol_version', 'protocol_incompatible', `does not accept protocol ${protocol}`)

  const slots = array('slots')
  slots?.forEach((slot, i) => { if (typeof slot !== 'string' || !slotPattern.test(slot)) error(`/slots/${i}`, 'schema_invalid', 'must be a slot id such as ui.dock') })

  const page = m['settings_page']
  if (page !== undefined && page !== null) {
    if (!isObject(page)) error('/settings_page', 'schema_invalid', 'must be a settings page declaration')
    else {
      for (const key of Object.keys(page)) if (!['page_id', 'title_key', 'order', 'category'].includes(key)) error(`/settings_page/${key}`, 'schema_invalid', 'is not a settings page field')
      if (typeof page['page_id'] !== 'string' || !/^[a-z][a-z0-9_]{0,31}$/.test(page['page_id'])) error('/settings_page/page_id', 'schema_invalid', 'must match ^[a-z][a-z0-9_]{0,31}$')
      if (typeof page['title_key'] !== 'string') error('/settings_page/title_key', 'schema_invalid', 'must be a string')
      if (typeof page['order'] !== 'number' || !Number.isInteger(page['order']) || page['order'] < -2_147_483_648 || page['order'] > 2_147_483_647) error('/settings_page/order', 'schema_invalid', 'must be a signed 32-bit integer')
      if (page['category'] !== undefined && page['category'] !== null && typeof page['category'] !== 'string') error('/settings_page/category', 'schema_invalid', 'must be a string or null')
    }
  }

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
    // The same support rule Core applies at install (#161), whatever defaults the schema declares.
    const support = configSchemaIssues(configSchema)
    for (const issue of support) error(issue.path, 'schema_invalid', issue.message)
    if (support.length === 0) {
      // Own keys only, as in json-schema.ts: a property named `toString` or a `default` on the prototype
      // is not a default.
      const own = (object: Obj, key: string) => Object.prototype.hasOwnProperty.call(object, key)
      const properties = own(configSchema, 'properties') ? configSchema['properties'] : undefined
      const defaults = Object.fromEntries(Object.entries((properties ?? {}) as Obj)
        .filter(([, sub]) => isObject(sub) && own(sub, 'default')).map(([key, sub]) => [key, (sub as Obj)['default']]))
      for (const issue of validateJsonSchema({ ...configSchema, required: [] }, defaults)) error(`/config_schema${issue.path}`, 'schema_invalid', `default ${issue.message}`)
    }
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
    if (!isObject(budget)) {
      error('/resource_budget', 'schema_invalid', 'must be an object')
    } else {
      // Rust ResourceBudget is closed, with two defaulted Option<u32> fields.
      // The generated schema's uint32 format is only an annotation, so check the domain here too.
      for (const key of Object.keys(budget)) {
        if (key !== 'memory_mib' && key !== 'cpu_percent') error(`/resource_budget/${key}`, 'schema_invalid', 'is not a resource budget field')
      }
      let exceedsServiceBudget = false
      for (const key of ['memory_mib', 'cpu_percent'] as const) {
        const value = budget[key]
        if (value === undefined || value === null) continue
        if (typeof value !== 'number' || !Number.isInteger(value) || value < 0 || value > 4_294_967_295) {
          error(`/resource_budget/${key}`, 'schema_invalid', 'must be null or an unsigned 32-bit integer (0..4294967295)')
        } else if (kind === 'service' && value > serviceBudget[key]) {
          exceedsServiceBudget = true
        }
      }
      if (exceedsServiceBudget) error('/resource_budget', 'budget_exceeded', `service plugins are capped at ${serviceBudget.memory_mib} MiB and ${serviceBudget.cpu_percent}%`)
    }
  }
  const rescue = m['rescue']
  if (rescue !== undefined && (!isObject(rescue) || typeof rescue['disable_safe'] !== 'boolean')) error('/rescue', 'schema_invalid', 'must be { "disable_safe": boolean }')

  return { ok: errors.length === 0, errors, warnings }
}
