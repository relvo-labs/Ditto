import { afterAll, beforeAll, expect, test } from 'vitest';
import { spawn, type ChildProcess } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import { mkdtemp, readdir, readFile, rm, stat } from 'node:fs/promises';
import { Socket } from 'node:net';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { check } from './schema-check.js';
import { protocolVersion } from './client.js';

/**
 * The TS half of the shared contract vectors (G1-QA-01). The Rust half is in
 * crates/ditto-core/src/tests.rs; both read tests/contract-vectors/0.2.
 */
const root = resolve(import.meta.dirname, '../../..');
const directory = join(root, 'tests/contract-vectors/0.2');
let child: ChildProcess;
let runtime: string;
let token: string;
let socketPath: string;

type Vector = Record<string, any>;

async function vectors(kind: string): Promise<[string, Vector][]> {
  const names = (await readdir(directory)).filter(name => name.endsWith('.json')).sort();
  const loaded = await Promise.all(names.map(async name => [name, JSON.parse(await readFile(join(directory, name), 'utf8'))] as [string, Vector]));
  return loaded.filter(([, vector]) => vector.kind === kind);
}

beforeAll(async () => {
  runtime = await mkdtemp(join(tmpdir(), 'ditto-vectors-'));
  token = randomBytes(24).toString('hex');
  socketPath = join(runtime, 'ditto/core.sock');
  child = spawn(join(root, 'target/debug/ditto-core'), ['serve', '--development', '--compositor', 'fixture'], {
    env: { ...process.env, XDG_RUNTIME_DIR: runtime, DITTO_DATA_DIR: join(runtime, 'store'), DITTO_SYSTEM: 'none', DITTO_DEV_TOKEN: token, SWAYSOCK: '', WAYFIRE_SOCKET: '' },
    stdio: ['ignore', 'ignore', 'pipe'],
  });
  for (let attempt = 0; attempt < 200; attempt++) {
    if (child.exitCode !== null) throw new Error(`Core exited: ${child.exitCode}`);
    try { await stat(socketPath); return; } catch { await new Promise(done => setTimeout(done, 20)); }
  }
  throw new Error('Core socket did not appear');
});

afterAll(async () => {
  if (child?.exitCode === null) child.kill('SIGTERM');
  if (runtime) await rm(runtime, { recursive: true, force: true });
});

test('shape vectors are judged by the Rust types\' JSON Schemas', async () => {
  const shapes = await vectors('shape');
  expect(shapes.length).toBeGreaterThan(0);
  for (const [name, vector] of shapes) {
    const schema = JSON.parse(await readFile(join(root, 'schema', `${vector.type}.json`), 'utf8'));
    const problems = check(schema, vector.value);
    if (vector.valid) expect(problems, name).toEqual([]);
    else expect(problems.length, `${name}: an invalid value was accepted`).toBeGreaterThan(0);
  }
});

/** One raw connection: lines in, lines out, no client library in between. */
class Wire {
  private buffer = '';
  private readonly socket = new Socket();
  private readonly waiting = new Map<string, (message: any) => void>();
  private next = 0;

  static async open(): Promise<Wire> {
    const wire = new Wire();
    await new Promise<void>((done, fail) => { wire.socket.once('error', fail); wire.socket.connect(socketPath, () => done()); });
    wire.socket.on('data', chunk => {
      wire.buffer += chunk.toString('utf8');
      let newline;
      while ((newline = wire.buffer.indexOf('\n')) >= 0) {
        const message = JSON.parse(wire.buffer.slice(0, newline));
        wire.buffer = wire.buffer.slice(newline + 1);
        if (message.method === undefined && typeof message.id === 'string') wire.waiting.get(message.id)?.(message);
      }
    });
    return wire;
  }

  send(method: string, params: unknown, id = `v-${++this.next}`): Promise<any> {
    return new Promise(done => {
      this.waiting.set(id, done);
      this.socket.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n');
    });
  }

  handshake(kind: string, version = protocolVersion): Promise<any> {
    return this.send('core.handshake', { protocol_version: version, client: { kind, version: '0.2.0' }, auth: { token } });
  }

  close(): void { this.socket.destroy(); }
}

function substitute(value: any, head: string, previous: any): any {
  if (value === '$head') return head;
  if (typeof value === 'string' && value.startsWith('$prev.')) {
    return value.slice('$prev.'.length).split('/').filter(Boolean).reduce((node: any, part) => node?.[part], previous) ?? null;
  }
  if (Array.isArray(value)) return value.map(item => substitute(item, head, previous));
  if (value && typeof value === 'object') return Object.fromEntries(Object.entries(value).map(([key, item]) => [key, substitute(item, head, previous)]));
  return value;
}

function pointer(value: any, path: string): any {
  return path.split('/').filter(Boolean).reduce((node: any, part) => node?.[part], value);
}

function expectStep(name: string, response: any, expectation: Vector, previous: any): void {
  if (expectation.error_name) expect(response.error?.name, `${name}: ${JSON.stringify(response)}`).toBe(expectation.error_name);
  if (expectation.error_reason) expect(response.error?.data?.reason, name).toBe(expectation.error_reason);
  for (const key of expectation.result_has ?? []) expect(response.result, name).toHaveProperty(key);
  if (expectation.result_path) expect(pointer(response.result, expectation.result_path), name).toEqual(substitute(expectation.equals, '', previous));
  if (expectation.every_scope_nonempty) {
    for (const item of response.result.capabilities) expect(item.resource_scope.length, `${name}: ${item.capability_id}`).toBeGreaterThan(0);
  }
}

test('scenario vectors hold against the Rust Core from TS', async () => {
  for (const [name, vector] of await vectors('scenario')) {
    const wire = await Wire.open();
    try {
      const kind = vector.client?.kind ?? 'dittoctl';
      const steps: Vector[] = vector.steps;
      if (steps[0]?.handshake) {
        expectStep(name, await wire.handshake(kind, vector.client?.protocol_version ?? protocolVersion), steps[0].expect, null);
        continue;
      }
      const hello = await wire.handshake(kind);
      expect(hello.result?.protocol_version, name).toBe(protocolVersion);
      let previous: any = null;
      for (const step of steps) {
        const head = (await wire.send('desktop.profiles.get', { _meta: { protocol_version: protocolVersion } })).result?.profile?.head_revision ?? '';
        const send = substitute(step.send, head, previous);
        const params = { ...send.params };
        if (!send.no_meta) params._meta = { protocol_version: protocolVersion, deadline_ms: 15_000, ...(send.on_behalf_of ? { on_behalf_of: send.on_behalf_of } : {}) };
        const response = await wire.send(send.method, params, send.id);
        expectStep(name, response, step.expect, previous);
        previous = response.result;
      }
    } finally { wire.close(); }
  }
});
