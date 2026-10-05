import { createHash } from 'node:crypto'
import { readdirSync, readFileSync } from 'node:fs'
import { join, relative } from 'node:path'
import { fileURLToPath } from 'node:url'

/** Filled in by scripts/build.mjs; source runs (tests, development) compute them from the tree. */
declare const __DITTO_HOSTD_VERSION__: string | undefined
declare const __DITTO_CORDIS_VERSION__: string | undefined
declare const __DITTO_VENDOR_FINGERPRINT__: string | undefined

export const hostdVersion = '0.2.0'

function files(dir: string): string[] {
  return readdirSync(dir, { withFileTypes: true }).flatMap(entry => {
    const path = join(dir, entry.name)
    return entry.isDirectory() ? files(path) : [path]
  })
}

/** sha256 over every vendored src file (path and bytes, sorted); the same algorithm as the build script. */
export function vendorFingerprint(vendorDir: string): string {
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

export function hostInfo(): { hostd_version: string; node_version: string; cordis_version: string; vendor_fingerprint: string } {
  const vendorDir = () => fileURLToPath(new URL('../vendor/', import.meta.url))
  return {
    hostd_version: typeof __DITTO_HOSTD_VERSION__ === 'string' ? __DITTO_HOSTD_VERSION__ : hostdVersion,
    node_version: process.versions.node,
    cordis_version: typeof __DITTO_CORDIS_VERSION__ === 'string'
      ? __DITTO_CORDIS_VERSION__
      : (JSON.parse(readFileSync(join(vendorDir(), 'cordis', 'package.json'), 'utf8')) as { version: string }).version,
    vendor_fingerprint: typeof __DITTO_VENDOR_FINGERPRINT__ === 'string' ? __DITTO_VENDOR_FINGERPRINT__ : vendorFingerprint(vendorDir()),
  }
}
