import { connect } from 'node:net'
import type { Duplex } from 'node:stream'
import { DittoError } from '../errors.ts'
import { RpcPeer } from './rpc.ts'

export const protocolVersion = '0.3.0'

export interface CallOptions {
  /** Entry this call is made for; Core maps it to `host:<entry_id>` if it assigned that entry here. */
  onBehalfOf?: string
  deadlineMs?: number
  operationId?: string
}

/** What the host runtime needs from Core. The socket client and test doubles both implement it. */
export interface CoreChannel {
  request<T>(method: string, params: Record<string, unknown>, options?: CallOptions): Promise<T>
}

export interface InboundHandlers {
  request(method: string, params: unknown): Promise<unknown>
  notification(method: string, params: unknown): void
  closed(error?: Error): void
}

export interface HandshakeResult {
  protocol_version: string
  subject?: string
  connection_id?: string
  host_generation: number | null
  mode?: 'normal' | 'rescue'
  [key: string]: unknown
}

export interface HelloResult {
  host_generation: number
  mode: 'normal' | 'rescue'
  heartbeat_interval_ms: number
  lease_ttl_ms: number
}

/**
 * hostd's connection to Core: one socket, requests both ways. Core-originated
 * requests (`participant.*`, `host.invoke`) and notifications
 * (`host.permission_revoked`, `desktop.events`) go to `handlers`.
 */
export class CoreLink implements CoreChannel {
  private readonly peer: RpcPeer
  private handlers?: InboundHandlers
  private readonly early: Array<() => void> = []

  private constructor(stream: Duplex) {
    this.peer = new RpcPeer(stream, 'hostd-', {
      request: (method, params) => {
        if (!this.handlers) return Promise.reject(new DittoError('unavailable', 'hostd is still starting', { reason: 'recovering' }))
        return this.handlers.request(method, params)
      },
      notification: (method, params) => {
        if (this.handlers) this.handlers.notification(method, params)
        else this.early.push(() => this.handlers?.notification(method, params))
      },
      closed: error => this.handlers?.closed(error),
    })
  }

  static async connectSocket(socketPath: string): Promise<CoreLink> {
    const socket = connect(socketPath)
    await new Promise<void>((resolve, reject) => {
      socket.once('connect', resolve)
      socket.once('error', reject)
    })
    return new CoreLink(socket)
  }

  static overStream(stream: Duplex): CoreLink {
    return new CoreLink(stream)
  }

  get closed(): boolean { return this.peer.isClosed }

  attach(handlers: InboundHandlers): void {
    this.handlers = handlers
    for (const replay of this.early.splice(0)) replay()
  }

  async handshake(token: string, client: { kind: string; version: string }): Promise<HandshakeResult> {
    const result = await this.peer.request<HandshakeResult>('core.handshake', {
      protocol_version: protocolVersion,
      client,
      auth: { token },
    })
    if (result.protocol_version !== protocolVersion) {
      throw new DittoError('protocol_version_unsupported', `Core negotiated ${result.protocol_version}`)
    }
    return result
  }

  request<T>(method: string, params: Record<string, unknown>, options: CallOptions = {}): Promise<T> {
    const deadlineMs = options.deadlineMs ?? 2_000
    const meta: Record<string, unknown> = { protocol_version: protocolVersion, deadline_ms: deadlineMs }
    if (options.onBehalfOf) meta['on_behalf_of'] = options.onBehalfOf
    if (options.operationId) meta['operation_id'] = options.operationId
    // Give Core the whole deadline plus transport slack before declaring the outcome unknown.
    return this.peer.request<T>(method, { ...params, _meta: meta }, deadlineMs + 1_000)
  }

  close(): void { this.peer.close() }
}
