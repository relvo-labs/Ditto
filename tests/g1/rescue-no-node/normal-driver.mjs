#!/usr/bin/env node
// Controlled CLI child of Core. Checks that hostd's real tasks service keeps
// its Core-managed data across a rescue-mode restart.
import { writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { connect, sleep } from '../lib/core-client.mjs';

const [work, phase, marker] = process.argv.slice(2);
const output = join(work, `${phase}.json`);

try {
  const { must, available } = await connect();
  const until = Date.now() + 40_000;
  while (!(await available(phase === 'before' ? 'desktop.tasks.add' : 'desktop.tasks.list'))) {
    if (Date.now() > until) throw new Error('tasks service did not become available');
    await sleep(200);
  }
  if (phase === 'before') await must('desktop.tasks.add', { text: marker, source: 'own' });
  const list = await must('desktop.tasks.list', {});
  const found = list.tasks.some(task => task.text === marker && task.source === 'own');
  writeFileSync(output, JSON.stringify({ ok: found, phase, marker, tasks: list.tasks }));
} catch (error) {
  writeFileSync(output, JSON.stringify({ ok: false, phase, error: String(error?.message ?? error) }));
}
