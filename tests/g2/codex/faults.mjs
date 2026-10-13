// Fault paths of the Codex backend with a scripted model that never answers:
// a user stop during the model call, and the app-server killed mid-turn.
// Development evidence only (QA-09/EX2-05 groundwork, no real account).
import {spawn} from 'node:child_process'
import {createHash} from 'node:crypto'
import {mkdtempSync,openSync,closeSync,readFileSync,existsSync,rmSync,chmodSync,readdirSync,statSync,realpathSync,writeFileSync} from 'node:fs'
import {tmpdir,homedir} from 'node:os'
import {resolve,join} from 'node:path'
import {fileURLToPath} from 'node:url'
import {startProvider} from './mock-provider.mjs'
import {exitUnlessConfinable} from '../lib/environment.mjs'
exitUnlessConfinable()

const workspace=fileURLToPath(new URL('../../../',import.meta.url))
const pin=JSON.parse(readFileSync(resolve(workspace,'tools/codex/pin.json'),'utf8'))
const candidate=process.env.DITTO_CODEX_BINARY??join(homedir(),'.local/bin/codex')
if(!existsSync(candidate)){console.log(JSON.stringify({ok:false,not_run:'pinned Codex binary not installed'}));process.exit(2)}
const codex=realpathSync(candidate)
if(createHash('sha256').update(readFileSync(codex)).digest('hex')!==pin.sha256){console.log(JSON.stringify({ok:false,not_run:'Codex binary differs from pin'}));process.exit(2)}

// The driver picks the model's behaviour per scenario through a file.
let modeFile
const provider=await startProvider(()=>{
  let mode='hang';try{mode=readFileSync(modeFile,'utf8').trim()||'hang'}catch{}
  return mode==='error'?{status:500}:mode
})
const root=mkdtempSync(tmpdir()+'/ditto-g2-faults-')
modeFile=root+'/model-mode'
const log=openSync(root+'/core.log','w')
const env={...process.env,DITTO_RUNTIME_DIR:root+'/run',DITTO_DATA_DIR:root+'/store',DITTO_SYSTEM:'none',DITTO_G2_TEST_OUT:root+'/result.json',DITTO_G2_PROVIDER_STATE:root+'/provider.json',DITTO_G2_MODEL_MODE:root+'/model-mode'}
for(const key of ['DITTO_DEV_TOKEN','DITTO_LAUNCH_SCOPE_PREFIX','DITTO_REQUIRE_QUOTA','WAYFIRE_SOCKET','SWAYSOCK'])delete env[key]
const child=spawn(resolve(workspace,'target/debug/ditto-core'),['serve','--compositor','fixture',
  '--builtin-packages',resolve(workspace,'target/ditto-packages'),
  '--hostd',`hostd 0.2.0 ${process.execPath} ${resolve(workspace,'packages/host-runtime/dist/ditto-hostd.mjs')}`,
  '--agent',`agent 0.3.0 ${process.execPath} ${resolve(workspace,'packages/agent-runtime/dist/ditto-agentd.mjs')}`,
  '--agent-backend',`codex-app-server ${pin.version} ${pin.sha256} ${codex}`,
  '--agent-backend-test-provider',`http://127.0.0.1:${provider.port}/v1`,
  '--launch',`dittoctl 0.3.0 ${process.execPath} ${resolve(workspace,'tests/g2/codex/faults-driver.mjs')}`,
],{env,stdio:['ignore',log,log],detached:true})
closeSync(log)
const sleep=ms=>new Promise(r=>setTimeout(r,ms))
// The driver asks for the provider's view through a file: how many model
// streams are open and which were closed by the client.
const publish=setInterval(()=>{try{writeFileSync(env.DITTO_G2_PROVIDER_STATE,JSON.stringify({requests:provider.requests.length,hanging:provider.hanging(),closed:provider.closed.length}))}catch{}},100)
try{
  for(let i=0;i<1800&&!existsSync(env.DITTO_G2_TEST_OUT);i++){if(child.exitCode!==null)throw new Error('Core exited');await sleep(100)}
  if(!existsSync(env.DITTO_G2_TEST_OUT))throw new Error('timed out')
  const result=JSON.parse(readFileSync(env.DITTO_G2_TEST_OUT,'utf8'))
  console.log(JSON.stringify({...result,evidence_class:process.env.DITTO_ENVIRONMENT_LABEL??'development-host',model:'scripted-loopback'}))
  if(!result.ok){console.error(readFileSync(root+'/core.log','utf8').slice(-6000));process.exitCode=1}
}catch(error){console.error(readFileSync(root+'/core.log','utf8').slice(-8000));console.log(JSON.stringify({ok:false,error:String(error)}));process.exitCode=1}
finally{
  clearInterval(publish)
  try{process.kill(-child.pid,'SIGTERM')}catch{}
  await sleep(300);try{process.kill(-child.pid,'SIGKILL')}catch{}
  await provider.close()
  function writable(p){if(statSync(p).isDirectory()){chmodSync(p,0o700);for(const n of readdirSync(p))writable(p+'/'+n)}else chmodSync(p,0o600)}
  writable(root);rmSync(root,{recursive:true,force:true})
}
