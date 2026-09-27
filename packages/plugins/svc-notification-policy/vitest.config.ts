import { defineConfig } from 'vitest/config'
import { vendorAlias } from '../../host-runtime/vendor-alias.mjs'

export default defineConfig({
  resolve: { alias: vendorAlias },
  define: { __DITTO_FAULT__: 'true' },
  test: { include: ['tests/**/*.test.ts'], testTimeout: 30_000 },
})
