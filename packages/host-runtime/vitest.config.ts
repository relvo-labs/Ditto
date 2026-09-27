import { defineConfig } from 'vitest/config'
import { vendorAlias } from './vendor-alias.mjs'

export default defineConfig({
  resolve: { alias: vendorAlias },
  // Test builds keep the hostd fault points; the production bundle defines false.
  define: { __DITTO_FAULT__: 'true' },
  test: { include: ['tests/**/*.test.ts'], testTimeout: 30_000, hookTimeout: 30_000 },
})
