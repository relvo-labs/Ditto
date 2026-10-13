import {build} from 'tsdown'
import {fileURLToPath} from 'node:url'
import {spawnSync} from 'node:child_process'
import {mkdtempSync,rmSync} from 'node:fs'
import {tmpdir} from 'node:os'
import {agentAliases} from '../vendor-alias.mjs'
const root=fileURLToPath(new URL('../',import.meta.url))
const output=mkdtempSync(tmpdir()+'/ditto-codex-probe-bundle-')
try{
  await build({config:false,cwd:root,tsconfig:'../host-runtime/tsconfig.build.json',entry:{probe:'tests/codex.probe.ts'},format:'esm',platform:'node',target:'node22',outDir:output,fixedExtension:true,dts:false,alias:agentAliases,outputOptions:{codeSplitting:false},logLevel:'warn'})
  const result=spawnSync(process.execPath,[output+'/probe.mjs'],{env:process.env,stdio:'inherit',timeout:60000,killSignal:'SIGTERM'})
  process.exitCode=result.status??1
}finally{rmSync(output,{recursive:true,force:true})}
