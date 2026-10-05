// Same algorithm as src/version.ts vendorFingerprint(); tests/process checks they agree.
import { createHash } from 'node:crypto'
import { readdirSync, readFileSync } from 'node:fs'
import { join, relative } from 'node:path'

function files(dir) {
  return readdirSync(dir, { withFileTypes: true }).flatMap(entry => {
    const path = join(dir, entry.name)
    return entry.isDirectory() ? files(path) : [path]
  })
}

export function vendorFingerprint(vendorDir) {
  const hash = createHash('sha256')
  const all = readdirSync(vendorDir, { withFileTypes: true })
    .filter(entry => entry.isDirectory())
    .flatMap(entry => files(join(vendorDir, entry.name, 'src')))
    .map(path => relative(vendorDir, path).split('\\').join('/'))
    .sort()
  for (const rel of all) {
    hash.update(rel + '\0')
    hash.update(readFileSync(join(vendorDir, rel)))
    hash.update('\0')
  }
  return `sha256:${hash.digest('hex')}`
}
