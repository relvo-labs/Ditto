// Whether this host can run the Codex backend at all: Core refuses it
// (isolation_unavailable) without Landlock ABI 6, which is correct and is
// reported as "environment", not as a failure of the suite.
import {spawnSync} from 'node:child_process'
import {resolve} from 'node:path'
import {fileURLToPath} from 'node:url'

const workspace=fileURLToPath(new URL('../../../',import.meta.url))
export function confinementAvailable(profile='debug'){
  const result=spawnSync(resolve(workspace,`target/${profile}/ditto-confine`),['--read','/usr','--','/usr/bin/true'],{encoding:'utf8'})
  return result.status===0
}
export function exitUnlessConfinable(profile){
  if(!confinementAvailable(profile)){
    console.log(JSON.stringify({ok:false,not_run:'this kernel cannot confine the Codex backend (Landlock ABI < 6); Core refuses it, as designed'}))
    process.exit(2)
  }
}
