// G2 Agent lifecycle (AGENT-01/09, CORE-01, QA-04 groundwork): the Agent
// with its confined Codex backend, under a scripted model.
//   mode "quick": ten concurrent wake-ups make one generation; 100 start/stop
//                 cycles leave no process behind and Core's memory flat
//   mode "idle":  real time — idle 5 min then gone within 10 s; a turn that
//                 runs longer than 5 min is not cut off
import {spawn} from 'node:child_process'
import {createHash} from 'node:crypto'
import {mkdtempSync,openSync,closeSync,readFileSync,existsSync,rmSync,chmodSync,readdirSync,lstatSync,realpathSync} from 'node:fs'
import {tmpdir,homedir} from 'node:os'
import {resolve,join} from 'node:path'
import {fileURLToPath} from 'node:url'
import {startProvider,say} from '../codex/mock-provider.mjs'

const mode=process.argv[2]??'quick'
const workspace=fileURLToPath(new URL('../../../',import.meta.url))
const pin=JSON.parse(readFileSync(resolve(workspace,'tools/codex/pin.json'),'utf8'))
const codex=realpathSync(process.env.DITTO_CODEX_BINARY??join(homedir(),'.local/bin/codex'))
if(createHash('sha256').update(readFileSync(codex)).digest('hex')!==pin.sha256){console.log(JSON.stringify({ok:false,not_run:'Codex binary differs from pin'}));process.exit(2)}
// A model that answers after a long time, for the "busy longer than idle"
// case; otherwise at once.
const provider=await startProvider(body=>JSON.stringify(body.input).includes('long-task')?'hang':[say('好。')])
const root=mkdtempSync(tmpdir()+'/ditto-g2-life-')
const log=openSync(root+'/core.log','w')
const env={...process.env,DITTO_RUNTIME_DIR:root+'/run',DITTO_DATA_DIR:root+'/store',DITTO_SYSTEM:'none',DITTO_G2_TEST_OUT:root+'/result.json',DITTO_G2_MODE:mode}
for(const k of ['DITTO_DEV_TOKEN','DITTO_LAUNCH_SCOPE_PREFIX','DITTO_REQUIRE_QUOTA','WAYFIRE_SOCKET','SWAYSOCK'])delete env[k]
const child=spawn(resolve(workspace,'target/debug/ditto-core'),['serve','--compositor','fixture',
  '--builtin-packages',resolve(workspace,'target/ditto-packages'),
  '--hostd',`hostd 0.2.0 ${process.execPath} ${resolve(workspace,'packages/host-runtime/dist/ditto-hostd.mjs')}`,
  '--agent',`agent 0.3.0 ${process.execPath} ${resolve(workspace,'packages/agent-runtime/dist/ditto-agentd.mjs')}`,
  '--agent-backend',`codex-app-server ${pin.version} ${pin.sha256} ${codex}`,
  '--agent-backend-test-provider',`http://127.0.0.1:${provider.port}/v1`,
  '--launch',`dittoctl 0.3.0 ${process.execPath} ${resolve(workspace,'tests/g2/lifecycle/driver.mjs')}`,
],{env,stdio:['ignore',log,log],detached:true})
closeSync(log)
const sleep=ms=>new Promise(r=>setTimeout(r,ms))
try{
  const limit=mode==='idle'?20*60*10:15*60*10
  for(let i=0;i<limit&&!existsSync(env.DITTO_G2_TEST_OUT);i++){if(child.exitCode!==null)throw new Error('Core exited');await sleep(100)}
  const result=JSON.parse(readFileSync(env.DITTO_G2_TEST_OUT,'utf8'))
  console.log(JSON.stringify({...result,mode,evidence_class:'development-host',model:'scripted-loopback'}))
  if(!result.ok){console.error(readFileSync(root+'/core.log','utf8').slice(-5000));process.exitCode=1}
}catch(error){console.error(readFileSync(root+'/core.log','utf8').slice(-5000));console.log(JSON.stringify({ok:false,mode,error:String(error)}));process.exitCode=1}
finally{
  try{process.kill(-child.pid,'SIGTERM')}catch{}
  await sleep(300);try{process.kill(-child.pid,'SIGKILL')}catch{}
  await provider.close()
  function writable(p){const s=lstatSync(p);if(s.isSymbolicLink())return;if(s.isDirectory()){chmodSync(p,0o700);for(const n of readdirSync(p))writable(p+'/'+n)}else chmodSync(p,0o600)}
  writable(root);rmSync(root,{recursive:true,force:true})
}
