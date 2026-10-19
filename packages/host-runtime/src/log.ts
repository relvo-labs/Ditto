import type { Context } from '@deepseek-ai/cordis'
import { createHmac, randomBytes } from 'node:crypto'
import { errorCodes } from './errors.ts'

// One private key per hostd process; never exported, logged or persisted.
const fingerprintKey = randomBytes(32)

export type LogLevel = 'error' | 'warn' | 'info' | 'debug'

export interface LogRecord {
  ts: string
  level: LogLevel
  msg: string
  [key: string]: unknown
}

export type LogSink = (record: LogRecord) => void

// Content is always private, regardless of its type (including Error/null).
const contentKeys = new Set(['title', 'summary', 'body', 'clipboard', 'text', 'content', 'window_title',
  'message', 'stack', 'payload', 'data', 'config', 'args', 'logger', 'name', 'topics'])

// Reviewed string fields only. Unknown fields/containers cannot bless nested
// strings by using a safe key. Error diagnostics have their own closed schema.
export const safeLogStringFields = [
  'component', 'part', 'source', 'entry_id', 'plugin_id', 'change_id',
  'grant_id', 'subscription_id', 'capability_id',
  'lease_id', 'presented', 'renewed', 'expired', 'method', 'key', 'status',
  'why', 'mode', 'strategy', 'point', 'action',
] as const
export const safeLogNumberFields = ['pid', 'bytes', 'timeout_ms', 'hit', 'host_generation',
  'min_semi_space_mib', 'max_semi_space_mib'] as const
export const safeLogBooleanFields = ['fixed', 'reclaim'] as const
const numberFields = new Set<string>(safeLogNumberFields)
const booleanFields = new Set<string>(safeLogBooleanFields)
const stringFields = new Set<string>(safeLogStringFields)
const errorNames = new Set(['Error', 'TypeError', 'RangeError', 'ReferenceError', 'SyntaxError',
  'URIError', 'EvalError', 'AggregateError', 'DittoError', 'NonError'])
const systemCodes = new Set(['EACCES', 'EPERM', 'ENOENT', 'ENOTDIR', 'EISDIR', 'ECONNREFUSED',
  'ECONNRESET', 'EPIPE', 'ETIMEDOUT', 'ENOMEM', 'EADDRINUSE', 'ENOSPC', 'EMFILE', 'ENFILE'])
// Fixed transaction failure categories; never keep the free text after ':'.
const reasonCodes = new Set([...Object.keys(errorCodes), 'module_load_failed', 'module_invalid',
  'config_invalid', 'import_failed', 'registration_refused', 'volatile_update_failed',
  'volatile_update_remounted', 'apply_failed', 'apply_timeout', 'health_failed', 'health_timeout',
  'not_active', 'cleanup_timeout', 'candidate_cleanup_timeout', 'entry_faulted',
  'unknown_change', 'change_in_progress', 'not_bound', 'host_unavailable', 'dependency_not_ready'])
// Host-authored event labels. An unknown/free-text message is grouped by hash,
// including when a caller uses HostLog or stderrSink directly.
const hostMessages = new Set(['host.message', 'cordis.error', 'cordis.message', 'host.fault',
  'participant.result', 'participant.refused', 'heap settings applied',
  'heap settings missing: start hostd with the flags in packages/host-runtime/hostd.node-flags',
  'connected', 'stopping', 'stop failed', 'hostd failed to start', 'unhandled rejection', 'uncaught exception',
  'background task failed', 'revocation for an entry with no revoke handler; Core will disable it',
  'revoke handler failed', 'event handler failed', 'event from a candidate dropped',
  'subscription refused', 'capability registration refused', 'event rejected by Core',
  'lease revoke failed', 'foreign lease ids presented', 'lease expired; registering again',
  're-registration failed', 'drain timed out; cancelling in-flight work', 'drain failed',
  'exported state exceeds 1 MiB; not handed over', 'exportState failed', 'dispose failed',
  'late cleanup finished; entry may be mounted again', 'cleanup timed out; entry marked faulted'])

interface ErrorDiagnostic { name: string; code?: number | string; fingerprint: string }

function safeCode(value: unknown): value is number | string {
  return typeof value === 'number' ? Object.values(errorCodes).some(code => code === value)
    : typeof value === 'string' && (systemCodes.has(value) || reasonCodes.has(value))
}

/** Group within this process without exposing a public hash of private text. */
export function errorDiagnostic(error: unknown): ErrorDiagnostic {
  const candidate = error as { name?: unknown; code?: unknown; errorName?: unknown; message?: unknown; fingerprint?: unknown } | null
  // Idempotent: stderrSink also guards callers that do not use HostLog.
  if (candidate && typeof candidate === 'object' && typeof candidate.name === 'string'
    && errorNames.has(candidate.name) && typeof candidate.fingerprint === 'string'
    && /^hmac-sha256:[a-f0-9]{64}$/.test(candidate.fingerprint)
    && (candidate.code === undefined || safeCode(candidate.code))) {
    return { name: candidate.name, ...(candidate.code !== undefined ? { code: candidate.code } : {}), fingerprint: candidate.fingerprint }
  }
  const closed = typeof candidate?.errorName === 'string' && Object.hasOwn(errorCodes, candidate.errorName)
    ? candidate.errorName as keyof typeof errorCodes : undefined
  const name = closed ? 'DittoError' : error instanceof Error && errorNames.has(error.name) ? error.name : error instanceof Error ? 'Error' : 'NonError'
  const reason = typeof error === 'string' ? error.split(':', 1)[0] : undefined
  const code = closed ? errorCodes[closed] : safeCode(candidate?.code) ? candidate.code
    : reason && reasonCodes.has(reason) ? reason : undefined
  let detail: string
  try { detail = error instanceof Error ? error.message : typeof error === 'string' ? error : JSON.stringify(error) ?? String(typeof error) }
  catch { detail = '[unserializable]' }
  const fingerprint = 'hmac-sha256:' + createHmac('sha256', fingerprintKey).update(JSON.stringify([name, code, detail])).digest('hex')
  return { name, ...(code !== undefined ? { code } : {}), fingerprint }
}

function redactPaths(text: string): string {
  const home = process.env['HOME']
  if (!home || home.length < 2) return text
  let result = '', rest = text
  while (rest.includes(home)) {
    const index = rest.indexOf(home)
    result += rest.slice(0, index) + '~/…'
    const after = rest.slice(index + home.length)
    const end = after.search(/[\s"',]/u)
    rest = end < 0 ? '' : after.slice(end)
  }
  return result + rest
}

function redact(key: string, value: unknown): unknown {
  if (contentKeys.has(key)) return '[redacted]'
  if (key === 'error' || key === 'reason' || value instanceof Error) return errorDiagnostic(value)
  if (key === 'message_fingerprint') return typeof value === 'string' && /^hmac-sha256:[a-f0-9]{64}$/.test(value) ? value : '[redacted]'
  if (typeof value === 'string') return stringFields.has(key) ? redactPaths(value) : '[redacted]'
  if (Array.isArray(value) && (key === 'items' || stringFields.has(key))) return value.map(item => redact(key, item))
  if (value && typeof value === 'object') {
    if (key !== 'items') return '[redacted]'
    return Object.fromEntries(Object.entries(value).map(([child, item]) => [child, redact(child, item)]))
  }
  if (typeof value === 'number' && numberFields.has(key)) return value
  if (typeof value === 'boolean' && booleanFields.has(key)) return value
  // V8's unspecified semi-space sizes are intentionally reported as null.
  if (value === null && (key === 'min_semi_space_mib' || key === 'max_semi_space_mib')) return null
  return '[redacted]'
}

function redactedRecord(record: LogRecord): LogRecord {
  const fields = Object.fromEntries(Object.entries(record).map(([key, value]) => [key, redact(key, value)]))
  return { ...fields, ts: record.ts, level: record.level,
    msg: hostMessages.has(record.msg) ? record.msg : 'host.message',
    ...(!hostMessages.has(record.msg) ? { message_fingerprint: errorDiagnostic(record.msg).fingerprint } : {}) }
}

/** journald collects stderr; redact before serialising even a direct sink call. */
export const stderrSink: LogSink = record => {
  process.stderr.write(JSON.stringify(redactedRecord(record)) + '\n')
}

export class HostLog {
  constructor(private sink: LogSink, private fields: Record<string, unknown> = {}) {}

  child(fields: Record<string, unknown>): HostLog {
    return new HostLog(this.sink, { ...this.fields, ...fields })
  }

  error(msg: string, fields?: Record<string, unknown>): void { this.write('error', msg, fields) }
  warn(msg: string, fields?: Record<string, unknown>): void { this.write('warn', msg, fields) }
  info(msg: string, fields?: Record<string, unknown>): void { this.write('info', msg, fields) }
  debug(msg: string, fields?: Record<string, unknown>): void { this.write('debug', msg, fields) }

  write(level: LogLevel, msg: string, fields?: Record<string, unknown>): void {
    try {
      this.sink(redactedRecord({ ...this.fields, ...fields, ts: new Date().toISOString(), level, msg }))
    } catch {
      // A broken sink must not take the host down with it.
    }
  }
}

const levels: Record<number, LogLevel> = { 0: 'error', 1: 'info', 2: 'warn', 3: 'debug' }

/**
 * Route Cordis logger output (plugin errors, disposer failures) into the host
 * log. Cordis keeps an in-memory buffer by default; without an exporter those
 * errors would never reach journald.
 */
export function installCordisExporter(root: Context, log: HostLog, minLevel = 2,
  identify?: (ctx: Context) => { entry_id: string; plugin_id: string }): void {
  root.logger.exporter({
    colors: false,
    levels: { default: minLevel },
    export(message) {
      const error = message.args.find((arg): arg is Error => arg instanceof Error)
      let identity: { entry_id: string; plugin_id: string } | undefined
      const ctx = message.fiber?.deref()?.ctx
      try { if (ctx) identity = identify?.(ctx) } catch { /* Root or already-disposed fiber. */ }
      log.write(levels[message.level] ?? 'info', error ? 'cordis.error' : 'cordis.message', {
        source: 'cordis',
        ...identity,
        error: errorDiagnostic(error ?? message.args),
      })
    },
  })
}
