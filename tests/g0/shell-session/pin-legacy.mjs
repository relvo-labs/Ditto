// Core launches this as dittoctl; authenticate immediately with its one-use
// launcher descriptor, then wait for run.sh to mark the post-boot log floor.
import { existsSync, renameSync, writeFileSync } from 'node:fs';
import { isDeepStrictEqual } from 'node:util';
import { connect, sleep } from '../../g1/lib/core-client.mjs';

const directory = process.argv[2];
if (!directory) throw new Error('usage: pin-legacy.mjs <fixture runtime>');
const save = result => {
  writeFileSync(`${directory}/legacy-pin.json.tmp`, JSON.stringify(result) + '\n');
  renameSync(`${directory}/legacy-pin.json.tmp`, `${directory}/legacy-pin.json`);
};
// Also bound a missing response; a disconnected or timed-out pin never passes.
const watchdog = setTimeout(() => {
  save({ status: 'failed', error: 'legacy pin driver timed out' });
  process.exit(1);
}, 45_000);
let core;
let change;
try {
  core = await connect();
  writeFileSync(`${directory}/legacy-pin.ready`, 'ready\n');
  while (!existsSync(`${directory}/legacy-pin.start`)) await sleep(50);
  const before = await core.must('desktop.profiles.get', {});
  const avatar = { ...before.document.avatar };
  delete avatar.presentation;
  change = await core.must('desktop.changes.propose', {
    base_revision: before.profile.head_revision,
    ops: [{ op: 'set_value', path: '/avatar', after: avatar }],
  });
  if (change.state !== 'committed') throw new Error(`legacy pin ended ${change.state}`);
  const after = await core.must('desktop.profiles.get', {});
  if (!isDeepStrictEqual(after.document.avatar, avatar) ||
      after.profile.head_revision !== change.committed_revision) {
    throw new Error('legacy pin Profile readback differs from the committed change');
  }
  save({ status: 'pinned', change, profile: after });
} catch (error) {
  save({ status: 'failed', error: String(error), change });
  process.exitCode = 1;
} finally {
  clearTimeout(watchdog);
  core?.close();
}
