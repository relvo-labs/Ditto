// NFR-13 (EX2-12) method, development host: 30 cold Agent starts with the
// release Core. Each run starts from no Agent process at all; the clock
// starts at the wake-up request (what the Shell sends when the person opens
// the chat) and stops when Core reports the controller ready, the confined
// Codex backend verified and the provider answering authenticated. The model
// is a loopback stand-in (no network, no login), so this is not the
// reference-machine measurement and says nothing about model first token.
import {spawn} from 'node:child_process'
import {createHash} from 'node:crypto'
import {mkdtempSync,openSync,closeSync,readFileSync,existsSync,rmSync,chmodSync,readdirSync,lstatSync,realpathSync,writeFileSync} from 'node:fs'
import {tmpdir,homedir} from 'node:os'
import {resolve,join} from 'node:path'
import {fileURLToPath} from 'node:url'
import {startProvider,say} from '../codex/mock-provider.mjs'

const runs=Number(process.argv[2]??30)
const workspace=fileURLToPath(new URL('../../../',import.meta.url))
const pin=JSON.parse(readFileSync(resolve(workspace,'tools/codex/pin.json'),'utf8'))
const codex=realpathSync(process.env.DITTO_CODEX_BINARY??join(homedir(),'.local/bin/codex'))
if(createHash('sha256').update(readFileSync(codex)).digest('hex')!==pin.sha256){console.log(JSON.stringify({ok:false,not_run:'Codex binary differs from pin'}));process.exit(2)}
const provider=await startProvider(()=>[say('好。')])
const root=mkdtempSync(tmpdir()+'/ditto-g2-cold-')
const log=openSync(root+'/core.log','w')
const env={...process.env,DITTO_RUNTIME_DIR:root+'/run',DITTO_DATA_DIR:root+'/store',DITTO_SYSTEM:'none',DITTO_G2_TEST_OUT:root+'/result.json',DITTO_G2_RUNS:String(runs)}
for(const k of ['DITTO_DEV_TOKEN','DITTO_LAUNCH_SCOPE_PREFIX','DITTO_REQUIRE_QUOTA','WAYFIRE_SOCKET','SWAYSOCK'])delete env[k]
const child=spawn(resolve(workspace,'target/release/ditto-core'),['serve','--compositor','fixture',
  '--builtin-packages',resolve(workspace,'target/ditto-packages'),
  '--hostd',`hostd 0.2.0 ${process.execPath} ${resolve(workspace,'packages/host-runtime/dist/ditto-hostd.mjs')}`,
  '--agent',`agent 0.3.0 ${process.execPath} ${resolve(workspace,'packages/agent-runtime/dist/ditto-agentd.mjs')}`,
  '--agent-backend',`codex-app-server ${pin.version} ${pin.sha256} ${codex}`,
  '--agent-backend-test-provider',`http://127.0.0.1:${provider.port}/v1`,
  '--launch',`dittoctl 0.3.0 ${process.execPath} ${resolve(workspace,'tests/g2/measure/cold-start-driver.mjs')}`,
],{env,stdio:['ignore',log,log],detached:true})
closeSync(log)
const sleep=ms=>new Promise(r=>setTimeout(r,ms))
try{
  for(let i=0;i<runs*200&&!existsSync(env.DITTO_G2_TEST_OUT);i++){if(child.exitCode!==null)throw new Error('Core exited');await sleep(100)}
  const result=JSON.parse(readFileSync(env.DITTO_G2_TEST_OUT,'utf8'))
  const out=resolve(workspace,'artifacts/g2/cold-start-'+new Date().toISOString().replace(/[:.]/g,'-')+'.json')
  ;(await import('node:fs')).mkdirSync(resolve(workspace,'artifacts/g2'),{recursive:true})
  writeFileSync(out,JSON.stringify({...result,environment:'development-host (reference machine hardware, fixture compositor, loopback model)',core:'release',codex:pin.version},null,1))
  console.log(JSON.stringify({ok:result.ok,summary:result.summary,artifact:out,error:result.error}))
}catch(error){console.error(readFileSync(root+'/core.log','utf8').slice(-4000));console.log(JSON.stringify({ok:false,error:String(error)}));process.exitCode=1}
finally{
  try{process.kill(-child.pid,'SIGTERM')}catch{}
  await sleep(300);try{process.kill(-child.pid,'SIGKILL')}catch{}
  await provider.close()
  function writable(p){const s=lstatSync(p);if(s.isSymbolicLink())return;if(s.isDirectory()){chmodSync(p,0o700);for(const n of readdirSync(p))writable(p+'/'+n)}else chmodSync(p,0o600)}
  writable(root);rmSync(root,{recursive:true,force:true})
}
