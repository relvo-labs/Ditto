// A minimal protocol 0.2 client for G1 verification drivers that Core starts
// through its launcher (token on DITTO_CORE_TOKEN_FD). Drivers are observers:
// they call capabilities and record what they see; run.sh does any killing.
import { Socket } from 'node:net';

export const PROTOCOL = '0.3.0';

function launcherToken() {
  return new Promise((resolve, reject) => {
    let text = '';
    const channel = new Socket({ fd: Number(process.env.DITTO_CORE_TOKEN_FD), readable: true, writable: false });
    channel.on('data', chunk => {
      text += chunk;
      if (text.includes('\n')) { channel.destroy(); resolve(text.trim()); }
    });
    channel.on('error', reject);
  });
}

export async function connect() {
  const socket = new Socket();
  await new Promise((resolve, reject) => { socket.once('error', reject); socket.connect(process.env.DITTO_CORE_SOCKET, resolve); });
  let buffer = '';
  let next = 0;
  const waiting = new Map();
  const events = [];
  const notifications = [];
  // A driver lives only as long as the Core that launched it: when Core ends,
  // so does the driver (a relay would otherwise keep listening forever).
  socket.on('close', () => process.exit(0));
  socket.on('data', chunk => {
    buffer += chunk.toString('utf8');
    let newline;
    while ((newline = buffer.indexOf('\n')) >= 0) {
      const message = JSON.parse(buffer.slice(0, newline));
      buffer = buffer.slice(newline + 1);
      if (message.method === 'desktop.events') events.push({ at: performance.now(), params: message.params });
      else if (message.method && message.id === undefined) notifications.push({ method: message.method, params: message.params });
      else if (message.id !== undefined && waiting.has(message.id)) { waiting.get(message.id)(message); waiting.delete(message.id); }
      else if (typeof message.id === 'string' && message.id.startsWith('core-')) {
        // Core-originated requests (participant calls) are not for drivers.
        socket.write(JSON.stringify({ jsonrpc: '2.0', id: message.id, error: { code: -32601, name: 'unsupported', message: 'verification driver' } }) + '\n');
      }
    }
  });
  const request = (method, params) => new Promise(resolve => {
    const id = `driver-${++next}`;
    waiting.set(id, resolve);
    socket.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n');
  });
  const call = (method, params = {}, meta = {}) => request(method, { ...params, _meta: { ...meta, protocol_version: PROTOCOL, deadline_ms: 15_000 } });
  const must = async (method, params, meta) => {
    const response = await call(method, params, meta);
    if (response.error) throw new Error(`${method}: ${response.error.name} ${response.error.message} ${JSON.stringify(response.error.data ?? {})}`);
    return response.result;
  };
  const hello = await request('core.handshake', {
    protocol_version: PROTOCOL,
    client: { kind: process.env.DITTO_CLIENT_KIND, version: process.env.DITTO_CLIENT_VERSION ?? '0.2.0' },
    auth: { token: await launcherToken() },
  });
  if (hello.error) throw new Error(`handshake refused: ${hello.error.name}`);
  const available = async id => {
    const listing = await must('desktop.capabilities.list', {});
    const item = listing.capabilities.find(capability => capability.capability_id === id);
    return item?.availability?.kind === 'always' || item?.availability?.available === true;
  };
  return { call, must, events, notifications, available, close: () => socket.destroy() };
}

export const sleep = ms => new Promise(done => setTimeout(done, ms));
