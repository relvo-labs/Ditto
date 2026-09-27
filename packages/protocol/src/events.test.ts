import { expect, test } from 'vitest';
import type { DesktopSnapshot } from './generated/desktop-snapshot.js';
import type { DesktopEventNotification } from './generated/desktop-event-notification.js';
import { DesktopProjection, ResyncRequired } from './events.js';

const empty: DesktopSnapshot = { outputs: [], workspaces: [], windows: [] };
const window = {
  id: 'session-1/window-1', title: 'Editor', app_id: 'editor', workspace_id: '1',
  x: 10, y: 20, width: 800, height: 600, focused: true, state: 'normal' as const,
};

function event(seq: number, payload: DesktopEventNotification['payload'], prev = seq - 1): DesktopEventNotification {
  return { subscription_id: 'sub-1', seq, prev_seq: prev, profile_revision: null, payload };
}

test('gaps in seq from other topics are fine; a broken prev_seq chain is not', () => {
  const projection = new DesktopProjection('sub-1', empty, 4);
  // seq 5 and 6 went to other topics; this subscription's chain says so.
  projection.apply(event(7, { type: 'window_upsert', window: { ...windowFixture } }, 4));
  expect(projection.seq).toBe(7);
  expect(() => projection.apply(event(9, { type: 'window_removed', window_id: windowFixture.id }, 8))).toThrow(ResyncRequired);
});

const windowFixture = {
  id: 'session-1/window-9', title: 'Terminal', app_id: 'foot', workspace_id: '1',
  x: 0, y: 0, width: 400, height: 300, focused: false, state: 'normal' as const,
};

test('applies ordered compositor events to a snapshot', () => {
  const projection = new DesktopProjection('sub-1', empty, 0);
  projection.apply(event(1, { type: 'window_upsert', window }));
  expect(projection.snapshot.windows.map(item => item.id)).toEqual([window.id]);
  projection.apply(event(2, { type: 'window_removed', window_id: window.id }));
  expect(projection.snapshot.windows).toEqual([]);
  expect(projection.seq).toBe(2);
});

test('a gap or explicit overflow requires a fresh snapshot', () => {
  const gap = new DesktopProjection('sub-1', empty, 0);
  expect(() => gap.apply(event(2, { type: 'window_upsert', window }))).toThrow(ResyncRequired);
  expect(gap.snapshot).toEqual(empty);
  expect(() => gap.apply(event(1, { type: 'window_upsert', window }))).toThrow(ResyncRequired);

  const overflow = new DesktopProjection('sub-1', empty, 0);
  expect(() => overflow.apply(event(4, { type: 'resync_required', reason: 'queue_overflow' }))).toThrow(ResyncRequired);
});
