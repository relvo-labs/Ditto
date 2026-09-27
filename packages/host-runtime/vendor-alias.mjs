// Vendored Cordis is consumed as TypeScript source: its package.json exports
// point at an unbuilt lib/, and Ditto keeps those manifests verbatim (see
// vendor/README.md). Vitest and tsdown resolve the scoped names through this map;
// tsconfig.host-base.json carries the same map for declarations.
import { fileURLToPath } from 'node:url'

/** The alias map for a vendor directory; bundled tools pass theirs explicitly. */
export function vendorAliasFor(vendor) {
  return {
  // Loader keeps equalExceptVolatile internal (not re-exported from its index); the
  // transaction layer must use the exact function Entry.update uses, not a copy.
  '@deepseek-ai/cordis-plugin-loader/diff': `${vendor}loader/src/config/diff.ts`,
  '@deepseek-ai/cordis-plugin-loader': `${vendor}loader/src/index.ts`,
  '@deepseek-ai/cordis-plugin-timer': `${vendor}timer/src/index.ts`,
  '@deepseek-ai/cordis': `${vendor}cordis/src/index.ts`,
  '@deepseek-ai/cosmokit': `${vendor}cosmokit/src/index.ts`,
  '@deepseek-ai/schemastery': `${vendor}schemastery/src/index.ts`,
  }
}

export const vendorAlias = vendorAliasFor(fileURLToPath(new URL('./vendor/', import.meta.url)))
