import type { Context } from '@deepseek-ai/cordis'
import { format } from 'node:util'

export type LogLevel = 'error' | 'warn' | 'info' | 'debug'

export interface LogRecord {
  ts: string
  level: LogLevel
  msg: string
  [key: string]: unknown
}

export type LogSink = (record: LogRecord) => void

/** journald collects stderr; one JSON object per line keeps fields queryable. */
export const stderrSink: LogSink = record => {
  process.stderr.write(JSON.stringify(record) + '\n')
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
      this.sink({ ts: new Date().toISOString(), level, msg, ...this.fields, ...fields })
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
export function installCordisExporter(root: Context, log: HostLog, minLevel = 2): void {
  root.logger.exporter({
    colors: false,
    levels: { default: minLevel },
    export(message) {
      const [first, ...rest] = message.args
      const error = message.args.find((arg): arg is Error => arg instanceof Error)
      const text = error ? error.message : typeof first === 'string' ? format(first, ...rest) : format(...message.args)
      log.write(levels[message.level] ?? 'info', text, {
        source: 'cordis',
        logger: message.name,
        ...(error?.stack ? { stack: error.stack } : {}),
      })
    },
  })
}
