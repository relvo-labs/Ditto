#!/usr/bin/env node
// A pass-through for Rust integration tests (crates/ditto-core/tests/lifecycle.rs)
// that need a Core in normal mode, where only clients Core launched itself can
// connect. Core starts this program through its launcher (usually as kind
// `dittoctl`); it completes the handshake with the token from
// DITTO_CORE_TOKEN_FD, then listens on the Unix socket named on its command
// line and copies bytes both ways between one test connection at a time and
// its Core connection. It adds nothing and decides nothing: the test speaks
// protocol 0.2 itself, under the identity Core bound to this process.
//
//   bridge.mjs <listen-socket>
import { rmSync } from 'node:fs';
import { createServer, Socket } from 'node:net';

const listen = process.argv[2];
if (!listen) {
  process.stderr.write('usage: bridge.mjs <listen-socket>\n');
  process.exit(2);
}

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

const token = await launcherToken();
const core = new Socket();
await new Promise((resolve, reject) => { core.once('error', reject); core.connect(process.env.DITTO_CORE_SOCKET, resolve); });
core.on('close', () => process.exit(0));

// Handshake, then keep whatever followed the answer for the test.
let pending = Buffer.alloc(0);
await new Promise((resolve, reject) => {
  const onData = chunk => {
    pending = Buffer.concat([pending, chunk]);
    const newline = pending.indexOf(10);
    if (newline < 0) return;
    const answer = JSON.parse(pending.subarray(0, newline).toString('utf8'));
    pending = pending.subarray(newline + 1);
    core.off('data', onData);
    if (answer.error) reject(new Error(`handshake refused: ${answer.error.name}`));
    else resolve();
  };
  core.on('data', onData);
  core.write(JSON.stringify({
    jsonrpc: '2.0', id: 'bridge-handshake', method: 'core.handshake',
    params: {
      protocol_version: '0.3.0',
      client: { kind: process.env.DITTO_CLIENT_KIND, version: process.env.DITTO_CLIENT_VERSION ?? '0.2.0' },
      auth: { token },
    },
  }) + '\n');
});

// Core's lines wait here while no test is connected.
let client;
core.on('data', chunk => {
  if (client) client.write(chunk);
  else pending = Buffer.concat([pending, chunk]);
});

rmSync(listen, { force: true });
createServer(socket => {
  if (client) { socket.destroy(); return; }
  client = socket;
  if (pending.length) { socket.write(pending); pending = Buffer.alloc(0); }
  socket.on('data', chunk => core.write(chunk));
  socket.on('close', () => { if (client === socket) client = undefined; });
  socket.on('error', () => {});
}).listen(listen, () => process.stderr.write(`[bridge] ready ${listen}\n`));
