import { fileURLToPath } from 'node:url'
import { defineConfig } from 'vitest/config'
import { vendorAlias } from '../host-runtime/vendor-alias.mjs'

// The example imports the SDK by its package name, as an author's plugin would.
const self = { '@ditto/host-sdk': fileURLToPath(new URL('./src/index.ts', import.meta.url)) }

export default defineConfig({
  resolve: { alias: { ...vendorAlias, ...self } },
  define: { __DITTO_FAULT__: 'true' },
  test: { include: ['tests/**/*.test.ts'], testTimeout: 60_000, hookTimeout: 30_000 },
})
