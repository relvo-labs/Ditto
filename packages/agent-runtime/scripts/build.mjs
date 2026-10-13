import {build} from 'tsdown'
import {fileURLToPath} from 'node:url'
import {readFileSync,writeFileSync} from 'node:fs'
import {agentAliases} from '../vendor-alias.mjs'
import {addVendorNotice} from '../../host-runtime/scripts/notice.mjs'
const root=fileURLToPath(new URL('../',import.meta.url))
await build({config:false,cwd:root,tsconfig:'../host-runtime/tsconfig.build.json',entry:{'ditto-agentd':'src/main.ts'},format:'esm',platform:'node',target:'node22',outDir:'dist',fixedExtension:true,dts:false,clean:true,sourcemap:false,alias:agentAliases,treeshake:true,outputOptions:{codeSplitting:false},logLevel:'warn'})
const output=root+'dist/ditto-agentd.mjs'
addVendorNotice(output,root+'../host-runtime/vendor',true)
const notices=[readFileSync(root+'vendor/harness/LICENSE','utf8')]
writeFileSync(output,'/*\n'+notices.join('\n\n').replaceAll('*/','* /')+'\n*/\n'+readFileSync(output,'utf8'))
