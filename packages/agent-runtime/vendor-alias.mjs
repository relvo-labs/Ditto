import { fileURLToPath } from 'node:url'
import { vendorAlias } from '../host-runtime/vendor-alias.mjs'
const root=fileURLToPath(new URL('./vendor/harness/',import.meta.url))
export const agentAliases={...vendorAlias,
  '@deepseek-ai/dsh-brand':root+'brand/index.ts',
  '@deepseek-ai/dsh-util-values':root+'values/index.ts',
  '@deepseek-ai/dsh-util-crypto':root+'crypto/index.ts',
  '@deepseek-ai/dsh-attachment':root+'attachment/types.ts',
}
