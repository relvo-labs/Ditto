// node ../host-sdk/scripts/build-plugins.mjs <package dir or glob-expanded dirs…>
import { existsSync } from 'node:fs'
import { join, resolve } from 'node:path'
import { bundlePlugin } from './bundle-plugin.mjs'

const dirs = process.argv.slice(2).map(dir => resolve(dir)).filter(dir => existsSync(join(dir, 'manifest.json')))
if (!dirs.length) {
  console.error('no plugin package directories given')
  process.exit(1)
}
for (const dir of dirs) {
  const out = await bundlePlugin(dir)
  if (out) console.log(out)
}
