import {defineConfig} from 'vitest/config'
import {agentAliases} from './vendor-alias.mjs'
export default defineConfig({resolve:{alias:agentAliases},test:{include:['tests/**/*.test.ts'],testTimeout:10000}})
