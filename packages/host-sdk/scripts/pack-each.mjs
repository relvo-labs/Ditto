// node pack-each.mjs [--no-handlers] <package dir>… --out <dir>
// Packs several plugin packages with the ditto-plugin CLI (one package.json, many packages).
import { spawnSync } from 'node:child_process'
import { existsSync } from 'node:fs'
import { join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const cli = fileURLToPath(new URL('../bin/ditto-plugin', import.meta.url))
const args = process.argv.slice(2)
const outAt = args.indexOf('--out')
const out = outAt >= 0 ? args.splice(outAt, 2)[1] : undefined
const flags = args.includes('--no-handlers') ? ['--no-handlers'] : []
if (flags.length) args.splice(args.indexOf('--no-handlers'), 1)
for (const dir of args.map(arg => resolve(arg)).filter(dir => existsSync(join(dir, 'manifest.json')))) {
  // Fault fixtures are built not to start; mounting them to look for handlers would only fail.
  const noHandlers = flags.length || /\/faults\//.test(dir) ? ['--no-handlers'] : []
  const run = spawnSync(cli, ['pack', dir, ...(out ? ['--out', out] : []), ...noHandlers], { stdio: 'inherit' })
  if (run.status !== 0) process.exit(run.status ?? 1)
}
