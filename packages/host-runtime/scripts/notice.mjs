// MIT asks that the copyright and permission notice travel with every copy.
// Bundles that inline vendored Cordis code get the notice as a leading comment.
// The vendor directory is passed in: this module is also bundled into the
// ditto-plugin CLI, where import.meta.url no longer points next to vendor/.
import { readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'

const marker = '/*!\n * Includes vendored Cordis'

export function vendorNotice(vendorDir) {
  const licence = readFileSync(join(vendorDir, 'cordis', 'LICENSE'), 'utf8').trim()
  return `${marker}, Cosmokit and Schemastery source (packages/host-runtime/vendor/,\n * DeepSeek Harness 477b4f4; upstream cordiverse/cordis and forks). Their licence:\n *\n${licence.split('\n').map(line => ` * ${line}`.trimEnd()).join('\n')}\n */\n`
}

/** Prepend the notice when the bundle inlines vendored code (or always); returns whether it did. */
export function addVendorNotice(file, vendorDir, always = false) {
  const code = readFileSync(file, 'utf8')
  if (code.startsWith(marker)) return true
  if (!always && !code.includes('host-runtime/vendor/')) return false
  writeFileSync(file, vendorNotice(vendorDir) + code)
  return true
}
