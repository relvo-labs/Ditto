#!/usr/bin/env node
// Agent stand-in (G1-QA-07). NOT an Agent: no model, no model SDK, no
// planning. It connects as client kind `agent` — through Core's controlled
// launcher (token on the descriptor in DITTO_CORE_TOKEN_FD) or, in
// development, DITTO_DEV_TOKEN — and does only three things:
//
//   subscribe <seconds>             follow tasks events; print one JSON line each
//   propose <ops.json> <operation>  send a ChangeSet with that _meta.operation_id
//   get <operation>                 look up the real outcome by operation id
//   hold                            connect, then wait to be killed (EX1-07 ①)
//
// Options before the command (L-10, crates/ditto-core/tests/lifecycle.rs):
//   --gate <file>   connect at once (the launcher token is short-lived), then
//                   wait until <file> exists before running the command
//   --out <file>    also write every printed line to <file>
//
// It exists to check that services and changes do not depend on the Agent's
// lifetime (AT-30, L-10) before there is an Agent. Reports call it
// 「Agent 替身」, never Agent. G2 decides whether it is deleted.
import { appendFileSync, existsSync, readFileSync } from 'node:fs';
import { Socket } from 'node:net';

const PROTOCOL = '0.3.0';

function socketPath() {
  if (process.env.DITTO_CORE_SOCKET) return process.env.DITTO_CORE_SOCKET;
  const directory = process.env.DITTO_RUNTIME_DIR ?? `${process.env.XDG_RUNTIME_DIR}/ditto`;
  return `${directory}/core.sock`;
}

async function token() {
  const fd = process.env.DITTO_CORE_TOKEN_FD;
  if (fd) {
    // Core hands the token over one end of a socketpair on this descriptor.
    return await new Promise((resolve, reject) => {
      let text = '';
      const channel = new Socket({ fd: Number(fd), readable: true, writable: false });
      channel.on('data', chunk => {
        text += chunk;
        if (text.includes('\n')) { channel.destroy(); resolve(text.trim()); }
      });
      channel.on('end', () => resolve(text.trim()));
      channel.on('error', reject);
    });
  }
  if (process.env.DITTO_DEV_TOKEN) return process.env.DITTO_DEV_TOKEN;
  throw new Error('no launcher token and no development token');
}

class Link {
  constructor(socket) {
    this.socket = socket;
    this.buffer = '';
    this.waiting = new Map();
    this.next = 0;
    this.onEvent = () => {};
    socket.on('data', chunk => {
      this.buffer += chunk.toString('utf8');
      let newline;
      while ((newline = this.buffer.indexOf('\n')) >= 0) {
        const message = JSON.parse(this.buffer.slice(0, newline));
        this.buffer = this.buffer.slice(newline + 1);
        if (message.method === 'desktop.events') this.onEvent(message.params);
        else if (typeof message.id === 'string') this.waiting.get(message.id)?.(message);
      }
    });
  }

  request(method, params) {
    const id = `standin-${++this.next}`;
    return new Promise(resolve => {
      this.waiting.set(id, resolve);
      this.socket.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n');
    });
  }

  call(method, params = {}, operationId) {
    return this.request(method, { ...params, _meta: { protocol_version: PROTOCOL, deadline_ms: 15_000, ...(operationId ? { operation_id: operationId } : {}) } });
  }
}

async function connect() {
  const socket = new Socket();
  await new Promise((resolve, reject) => { socket.once('error', reject); socket.connect(socketPath(), resolve); });
  const link = new Link(socket);
  const hello = await link.request('core.handshake', {
    protocol_version: PROTOCOL,
    client: { kind: process.env.DITTO_CLIENT_KIND ?? 'agent', version: process.env.DITTO_CLIENT_VERSION ?? '0.2.0' },
    auth: { token: await token() },
  });
  if (hello.error) throw new Error(`handshake refused: ${hello.error.name} ${hello.error.message}`);
  return link;
}

const args = process.argv.slice(2);
const options = {};
while (args[0] === '--gate' || args[0] === '--out') {
  const [flag, value] = args.splice(0, 2);
  options[flag.slice(2)] = value;
}
const [command, ...rest] = args;
const link = await connect();
const print = value => {
  const line = JSON.stringify(value) + '\n';
  process.stdout.write(line);
  if (options.out) appendFileSync(options.out, line);
};
if (options.gate) {
  print({ connected: true, pid: process.pid, waiting: options.gate });
  while (!existsSync(options.gate)) await new Promise(resolve => setTimeout(resolve, 10));
}
switch (command) {
  case 'subscribe': {
    const seconds = Number(rest[0] ?? 30);
    link.onEvent = event => print({ at: new Date().toISOString(), event });
    print(await link.call('desktop.events.subscribe', { topics: ['tasks', 'changes'] }));
    setTimeout(() => process.exit(0), seconds * 1000);
    break;
  }
  case 'propose': {
    const [file, operationId] = rest;
    const body = JSON.parse(readFileSync(file, 'utf8'));
    if (!body.base_revision) {
      const head = await link.call('desktop.profiles.get');
      body.base_revision = head.result?.profile?.head_revision;
    }
    const answer = link.call('desktop.changes.propose', body, operationId);
    print({ sent: 'desktop.changes.propose', operation_id: operationId ?? null });
    print(await answer);
    process.exit(0);
    break;
  }
  case 'get':
    print(await link.call('desktop.changes.get', { operation_id: rest[0] }));
    process.exit(0);
    break;
  case 'hold':
    print({ connected: true, pid: process.pid });
    // Held until killed, or until the Core that launched it ends.
    link.socket.on('close', () => process.exit(0));
    setInterval(() => {}, 1 << 30);
    break;
  default:
    process.stderr.write('usage: standin.mjs subscribe SECONDS | propose OPS.json OPERATION_ID | get OPERATION_ID | hold\n');
    process.exit(2);
}
