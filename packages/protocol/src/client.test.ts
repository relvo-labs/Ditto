import { afterAll, beforeAll, expect, test } from 'vitest';
import { spawn, type ChildProcess } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import { mkdtemp, rm, stat } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { CoreError, DittoClient } from './client.js';

const root = resolve(import.meta.dirname, '../../..');
const tiled = 'fixture-window-1';
const floating = 'fixture-window-2';
let child: ChildProcess;
let runtime: string;
let token: string;
let socketPath: string;

beforeAll(async () => {
  runtime = await mkdtemp(join(tmpdir(), 'ditto-contract-'));
  token = randomBytes(24).toString('hex');
  socketPath = join(runtime, 'ditto/core.sock');
  child = spawn(join(root, 'target/debug/ditto-core'), ['serve', '--development', '--compositor', 'fixture'], {
    env: { ...process.env, XDG_RUNTIME_DIR: runtime, DITTO_DEV_TOKEN: token, SWAYSOCK: '' },
    stdio: ['ignore', 'ignore', 'pipe'],
  });
  for (let attempt = 0; attempt < 100; attempt++) {
    if (child.exitCode !== null) throw new Error(`Core exited: ${child.exitCode}`);
    try { await stat(socketPath); return; } catch { await new Promise(resolve => setTimeout(resolve, 20)); }
  }
  throw new Error('Core socket did not appear');
});

afterAll(async () => {
  if (child?.exitCode === null) child.kill('SIGTERM');
  if (runtime) await rm(runtime, { recursive: true, force: true });
});

async function connect(): Promise<DittoClient> {
  const { client } = await DittoClient.connect(socketPath, token);
  return client;
}

test('the TS client reads the Rust catalog with availability resolved', async () => {
  const client = await connect();
  try {
    const catalog = await client.capabilities();
    expect(catalog.capabilities).toHaveLength(13);
    const list = catalog.capabilities.find(item => item.capability_id === 'desktop.capabilities.list');
    expect(list?.claimable).toBe(false);
    expect(list?.availability.kind).toBe('always');
    const move = catalog.capabilities.find(item => item.capability_id === 'desktop.windows.move');
    expect(move?.availability).toMatchObject({ kind: 'depends_on_compositor', matrix_row: 'C-04', available: true });
    expect(move?.readback).toBe('desktop.windows.get');
    const close = catalog.capabilities.find(item => item.capability_id === 'desktop.windows.close_request');
    expect(close?.claimable).toBe(false);
    expect(close?.idempotency).toBe('key-based');
  } finally { client.close(); }
});

test('a write is confirmed by reading the state back', async () => {
  const client = await connect();
  try {
    const focused = await client.focusWindow(floating);
    expect(focused.focused).toBe(true);
    const moved = await client.moveWindow(floating, 24, 48);
    expect([moved.x, moved.y]).toEqual([24, 48]);
    const observed = await client.window(floating);
    expect([observed.x, observed.y]).toEqual([24, 48]);
  } finally { client.close(); }
});

test('an operation the compositor cannot perform answers unsupported', async () => {
  const client = await connect();
  try {
    await expect(client.moveWindow(tiled, 10, 10)).rejects.toBeInstanceOf(CoreError);
    await expect(client.moveWindow(tiled, 10, 10)).rejects.toMatchObject({ code: -32000, errorName: 'unsupported' });
    await expect(client.setWindowState(tiled, 'minimized')).rejects.toMatchObject({ errorName: 'unsupported' });
    await expect(client.window('fixture-window-404')).rejects.toMatchObject({ errorName: 'not_found' });
  } finally { client.close(); }
});

test('a subscription starts from a snapshot and follows ordered events', async () => {
  const client = await connect();
  try {
    const changes: number[] = [];
    const subscription = await client.subscribe({ onChange: projection => changes.push(projection.seq) });
    expect(subscription.projection.snapshot.windows.length).toBeGreaterThan(0);
    expect(subscription.resynced).toBe(false);
    await client.activateWorkspace('2');
    await new Promise(resolve => setTimeout(resolve, 200));
    expect(changes.length).toBeGreaterThan(0);
    const active = subscription.projection.snapshot.workspaces.find(item => item.active);
    expect(active?.id).toBe('2');
  } finally { client.close(); }
});

test('a sequence outside the retained window is answered with a fresh snapshot', async () => {
  const client = await connect();
  try {
    const subscription = await client.subscribe({ afterSeq: 100_000 });
    expect(subscription.resynced).toBe(true);
  } finally { client.close(); }
});

test('Core rejects an unauthorised client and self-declared identity', async () => {
  await expect(DittoClient.connect(socketPath, 'wrong'))
    .rejects.toMatchObject({ code: -32009, errorName: 'identity_rejected' });
});

test('the hot path counter tracks every request the client issues', async () => {
  const client = await connect();
  try {
    client.resetRequestCount();
    expect(client.requestCount).toBe(0);
    await client.windows();
    expect(client.requestCount).toBe(1);
  } finally { client.close(); }
});
