import { Socket } from 'node:net';
import type { CapabilitiesListOutput } from './generated/capabilities-list-output.js';
import type { CloseRequestOutput } from './generated/close-request-output.js';
import type { DesktopEventNotification } from './generated/desktop-event-notification.js';
import type { EventsSubscribeOutput } from './generated/events-subscribe-output.js';
import type { HandshakeOutput } from './generated/handshake-output.js';
import type { Output } from './generated/output.js';
import type { OutputsListOutput } from './generated/outputs-list-output.js';
import type { Window } from './generated/window.js';
import type { WindowsListOutput } from './generated/windows-list-output.js';
import type { Workspace } from './generated/workspace.js';
import type { WorkspacesListOutput } from './generated/workspaces-list-output.js';
import { DesktopProjection, ResyncRequired } from './events.js';

export const protocolVersion = '0.2.0';
const maxLineBytes = 1_048_576;

type Response = {
  jsonrpc: '2.0';
  id?: string;
  method?: string;
  params?: unknown;
  result?: unknown;
  error?: { code: number; name: string; message: string; outcome?: 'unknown' };
};

export class CoreError extends Error {
  constructor(readonly code: number, readonly errorName: string, message: string) {
    super(message);
  }
}

export type Subscription = {
  projection: DesktopProjection;
  /** True when Core could not replay from the requested sequence. */
  resynced: boolean;
};

/** G0 client for the desktop capabilities Core routes. */
export class DittoClient {
  private readonly socket = new Socket();
  private readonly pending = new Map<string, { resolve: (value: unknown) => void; reject: (reason: Error) => void; timer: NodeJS.Timeout }>();
  private readonly eventHandlers = new Set<(event: DesktopEventNotification) => void>();
  private buffer = Buffer.alloc(0);
  private nextId = 0;
  private connected = false;
  private requests = 0;

  private constructor() {
    this.socket.on('data', chunk => this.onData(chunk));
    this.socket.on('error', error => this.failPending(error));
    this.socket.on('close', () => {
      this.connected = false;
      this.failPending(new Error('Core connection closed'));
    });
  }

  static async connect(
    socketPath: string,
    token: string,
    client: { kind: string; version: string } = { kind: 'dittoctl', version: '0.2.0' },
  ): Promise<{ client: DittoClient; handshake: HandshakeOutput }> {
    const instance = new DittoClient();
    try {
      await new Promise<void>((resolve, reject) => {
        instance.socket.once('error', reject);
        instance.socket.connect(socketPath, () => {
          instance.socket.off('error', reject);
          resolve();
        });
      });
      const handshake = await instance.call<HandshakeOutput>('core.handshake', {
        protocol_version: protocolVersion,
        client,
        auth: { token },
      });
      if (handshake.protocol_version !== protocolVersion) throw new Error('Core negotiated an unexpected protocol version');
      instance.connected = true;
      return { client: instance, handshake };
    } catch (error) {
      instance.close();
      throw error;
    }
  }

  /** Requests issued since the last reset; the hot path must add none. */
  get requestCount(): number { return this.requests; }
  resetRequestCount(): void { this.requests = 0; }

  capabilities(): Promise<CapabilitiesListOutput> {
    return this.capability<CapabilitiesListOutput>('desktop.capabilities.list', {});
  }

  outputs(): Promise<OutputsListOutput> {
    return this.capability<OutputsListOutput>('desktop.outputs.list', {});
  }

  workspaces(): Promise<WorkspacesListOutput> {
    return this.capability<WorkspacesListOutput>('desktop.workspaces.list', {});
  }

  workspace(workspaceId: string): Promise<Workspace> {
    return this.capability<Workspace>('desktop.workspaces.get', { workspace_id: workspaceId });
  }

  activateWorkspace(workspaceId: string): Promise<Workspace> {
    return this.capability<Workspace>('desktop.workspaces.activate', { workspace_id: workspaceId });
  }

  windows(): Promise<WindowsListOutput> {
    return this.capability<WindowsListOutput>('desktop.windows.list', {});
  }

  window(windowId: string): Promise<Window> {
    return this.capability<Window>('desktop.windows.get', { window_id: windowId });
  }

  focusWindow(windowId: string): Promise<Window> {
    return this.capability<Window>('desktop.windows.focus', { window_id: windowId });
  }

  moveWindow(windowId: string, x: number, y: number): Promise<Window> {
    return this.capability<Window>('desktop.windows.move', { window_id: windowId, x, y });
  }

  resizeWindow(windowId: string, width: number, height: number): Promise<Window> {
    return this.capability<Window>('desktop.windows.resize', { window_id: windowId, width, height });
  }

  setWindowState(windowId: string, state: Window['state']): Promise<Window> {
    return this.capability<Window>('desktop.windows.set_state', { window_id: windowId, state });
  }

  /** Delivery only: confirm the outcome through an event or windows.list. */
  closeRequest(windowId: string, operationId: string): Promise<CloseRequestOutput> {
    return this.capability<CloseRequestOutput>('desktop.windows.close_request', { window_id: windowId }, operationId);
  }

  /**
   * Subscribe and keep a projection in step. A sequence gap or an overflow ends
   * the subscription; `onResync` is called and a new snapshot is taken, because
   * state is only ever rebuilt from snapshot plus events.
   */
  async subscribe(options: { afterSeq?: number; onChange?: (projection: DesktopProjection) => void; onResync?: (reason: string) => void } = {}): Promise<Subscription> {
    const output = await this.capability<EventsSubscribeOutput>('desktop.events.subscribe', options.afterSeq === undefined ? {} : { after_seq: options.afterSeq });
    let projection = new DesktopProjection(output.subscription_id, output.snapshot, output.seq);
    const subscription: Subscription = { projection, resynced: output.resynced === true };
    this.eventHandlers.add(event => {
      if (event.subscription_id !== projection.subscriptionId) return;
      try {
        projection.apply(event);
        options.onChange?.(projection);
      } catch (error) {
        if (!(error instanceof ResyncRequired)) throw error;
        options.onResync?.(error.message);
        void this.capability<EventsSubscribeOutput>('desktop.events.subscribe', {}).then(fresh => {
          projection = new DesktopProjection(fresh.subscription_id, fresh.snapshot, fresh.seq);
          subscription.projection = projection;
          subscription.resynced = true;
          options.onChange?.(projection);
        });
      }
    });
    return subscription;
  }

  onEvent(handler: (event: DesktopEventNotification) => void): void {
    this.eventHandlers.add(handler);
  }

  /** Ask Core to cancel a request. Core refuses rather than pretending. */
  cancel(requestId: string): void {
    this.socket.write(Buffer.from(JSON.stringify({ jsonrpc: '2.0', method: '$/cancel', params: { id: requestId } }) + '\n'));
  }

  close(): void {
    this.socket.destroy();
  }

  private capability<T>(capabilityId: string, params: object, operationId?: string): Promise<T> {
    if (!this.connected) return Promise.reject(new Error('Core handshake has not completed'));
    return this.call<T>(capabilityId, {
      ...params,
      _meta: { protocol_version: protocolVersion, deadline_ms: 2_000, ...(operationId ? { operation_id: operationId } : {}) },
    });
  }

  private call<T>(method: string, params: object): Promise<T> {
    const id = `ts-${++this.nextId}`;
    this.requests += 1;
    const body = Buffer.from(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n');
    if (body.length > maxLineBytes) return Promise.reject(new Error('request exceeds 1 MiB'));
    return new Promise<T>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`Core request timed out: ${method}`));
      }, 5_000);
      this.pending.set(id, { resolve: value => resolve(value as T), reject, timer });
      this.socket.write(body, error => {
        if (error) {
          clearTimeout(timer);
          this.pending.delete(id);
          reject(error);
        }
      });
    });
  }

  private onData(chunk: Buffer): void {
    this.buffer = Buffer.concat([this.buffer, chunk]);
    while (true) {
      const newline = this.buffer.indexOf(10);
      if (newline < 0) {
        if (this.buffer.length > maxLineBytes) this.socket.destroy(new Error('response exceeds 1 MiB'));
        return;
      }
      if (newline + 1 > maxLineBytes) {
        this.socket.destroy(new Error('response exceeds 1 MiB'));
        return;
      }
      const line = this.buffer.subarray(0, newline);
      this.buffer = this.buffer.subarray(newline + 1);
      let message: Response;
      try { message = JSON.parse(line.toString('utf8')) as Response; }
      catch { continue; }
      if (message.jsonrpc !== '2.0') continue;
      if (message.method === 'desktop.events') {
        const event = message.params as DesktopEventNotification;
        for (const handler of this.eventHandlers) handler(event);
        continue;
      }
      if (typeof message.id !== 'string') continue;
      const pending = this.pending.get(message.id);
      if (!pending) continue;
      this.pending.delete(message.id);
      clearTimeout(pending.timer);
      if (message.error) pending.reject(new CoreError(message.error.code, message.error.name, message.error.message));
      else if (message.result !== undefined) pending.resolve(message.result);
      else pending.reject(new Error('Core response has neither result nor error'));
    }
  }

  private failPending(error: Error): void {
    for (const pending of this.pending.values()) {
      clearTimeout(pending.timer);
      pending.reject(error);
    }
    this.pending.clear();
  }
}

export type { Output, Window, Workspace, DesktopProjection };
