import type { Duplex } from 'node:stream'
import { DittoError, toWireError, type WireError } from '../errors.ts'

const maxLineBytes = 1_048_576

interface Message {
  jsonrpc: '2.0'
  id?: string | number | null
  method?: string
  params?: unknown
  result?: unknown
  error?: WireError
}

export interface RpcHandlers {
  /** Peer-originated request; the resolved value becomes `result`, a throw becomes `error`. */
  request(method: string, params: unknown, id: string): Promise<unknown>
  notification(method: string, params: unknown): void
  closed(error?: Error): void
}

/**
 * Newline-framed JSON-RPC 2.0 in both directions over one stream (protocol
 * 0.2 §1). Outgoing ids carry `idPrefix`; Core's own ids start with `core-`,
 * so the two never collide.
 */
export class RpcPeer {
  private buffer: Buffer = Buffer.alloc(0)
  private nextId = 0
  private closed = false
  private readonly pending = new Map<string, { resolve: (value: unknown) => void; reject: (error: Error) => void; timer: NodeJS.Timeout }>()

  constructor(private readonly stream: Duplex, private readonly idPrefix: string, private readonly handlers: RpcHandlers) {
    stream.on('data', (chunk: Buffer) => this.onData(chunk))
    stream.on('error', error => this.shutdown(error))
    stream.on('close', () => this.shutdown())
  }

  get isClosed(): boolean { return this.closed }

  request<T>(method: string, params: unknown, timeoutMs = 5_000): Promise<T> {
    if (this.closed) return Promise.reject(new DittoError('unavailable', 'Core connection closed', { reason: 'host_unavailable' }))
    const id = `${this.idPrefix}${++this.nextId}`
    const line = JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n'
    if (Buffer.byteLength(line) > maxLineBytes) return Promise.reject(new DittoError('invalid_params', 'request exceeds 1 MiB'))
    return new Promise<T>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id)
        reject(new DittoError('timeout', `no response to ${method}`, undefined, 'unknown'))
      }, timeoutMs)
      timer.unref()
      this.pending.set(id, { resolve: value => resolve(value as T), reject, timer })
      this.stream.write(line)
    })
  }

  notify(method: string, params: unknown): void {
    if (this.closed) return
    this.stream.write(JSON.stringify({ jsonrpc: '2.0', method, params }) + '\n')
  }

  close(): void {
    this.stream.destroy()
    this.shutdown()
  }

  private respond(id: string, body: { result: unknown } | { error: WireError }): void {
    if (this.closed) return
    let line = JSON.stringify({ jsonrpc: '2.0', id, ...body }) + '\n'
    if (Buffer.byteLength(line) > maxLineBytes) {
      line = JSON.stringify({ jsonrpc: '2.0', id, error: new DittoError('internal', 'response exceeds 1 MiB').toWire() }) + '\n'
    }
    this.stream.write(line)
  }

  private onData(chunk: Buffer): void {
    this.buffer = this.buffer.length ? Buffer.concat([this.buffer, chunk]) : chunk
    while (true) {
      const newline = this.buffer.indexOf(10)
      if (newline < 0) {
        if (this.buffer.length > maxLineBytes) this.stream.destroy(new Error('frame exceeds 1 MiB'))
        return
      }
      const line = this.buffer.subarray(0, newline)
      this.buffer = this.buffer.subarray(newline + 1)
      if (line.length > maxLineBytes) {
        this.stream.destroy(new Error('frame exceeds 1 MiB'))
        return
      }
      let message: Message
      try { message = JSON.parse(line.toString('utf8')) as Message } catch { continue }
      if (message.jsonrpc !== '2.0') continue
      this.dispatch(message)
    }
  }

  private dispatch(message: Message): void {
    if (typeof message.method === 'string') {
      if (message.id === undefined || message.id === null) {
        try { this.handlers.notification(message.method, message.params) } catch { /* handler logs */ }
        return
      }
      const id = String(message.id)
      this.handlers.request(message.method, message.params, id).then(
        result => this.respond(id, { result: result ?? {} }),
        error => this.respond(id, { error: toWireError(error) }),
      )
      return
    }
    if (typeof message.id !== 'string') return
    const pending = this.pending.get(message.id)
    if (!pending) return
    this.pending.delete(message.id)
    clearTimeout(pending.timer)
    if (message.error) pending.reject(DittoError.fromWire(message.error))
    else pending.resolve(message.result)
  }

  private shutdown(error?: Error): void {
    if (this.closed) return
    this.closed = true
    for (const pending of this.pending.values()) {
      clearTimeout(pending.timer)
      pending.reject(new DittoError('unavailable', 'Core connection closed', { reason: 'host_unavailable' }, 'unknown'))
    }
    this.pending.clear()
    this.handlers.closed(error)
  }
}
