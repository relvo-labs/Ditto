// Production launcher identity, Core persistence and the real Cordis
// controller. Uses a private fixture store; never starts a model or logs in.
import {spawn} from 'node:child_process'
import {mkdtempSync,openSync,closeSync,readFileSync,existsSync,rmSync,chmodSync,readdirSync,statSync} from 'node:fs'
import {tmpdir} from 'node:os'
import {resolve} from 'node:path'
import {fileURLToPath} from 'node:url'

const workspace=fileURLToPath(new URL('../../../',import.meta.url))
const root=mkdtempSync(tmpdir()+'/ditto-g2-')
const log=openSync(root+'/core.log','w')
const env={...process.env,DITTO_RUNTIME_DIR:root+'/run',DITTO_DATA_DIR:root+'/store',DITTO_SYSTEM:'none',DITTO_G2_TEST_OUT:root+'/result.json'}
for(const key of ['DITTO_DEV_TOKEN','DITTO_LAUNCH_SCOPE_PREFIX','DITTO_REQUIRE_QUOTA','WAYFIRE_SOCKET','SWAYSOCK'])delete env[key]
const child=spawn(resolve(workspace,'target/debug/ditto-core'),['serve','--compositor','fixture',
  '--builtin-packages',resolve(workspace,'target/ditto-packages'),
  '--hostd',`hostd 0.2.0 ${process.execPath} ${resolve(workspace,'packages/host-runtime/dist/ditto-hostd.mjs')}`,
  '--agent',`agent 0.3.0 ${process.execPath} ${resolve(workspace,process.env.DITTO_G2_BOUNDARY_TEST?'tests/g2/foundation/agent-boundary.mjs':'packages/agent-runtime/dist/ditto-agentd.mjs')}`,
  '--launch',`dittoctl 0.3.0 ${process.execPath} ${resolve(workspace,'tests/g2/foundation/driver.mjs')}`,
],{env,stdio:['ignore',log,log],detached:true})
closeSync(log)
const sleep=ms=>new Promise(resolve=>setTimeout(resolve,ms))
try{
  for(let i=0;i<750&&!existsSync(env.DITTO_G2_TEST_OUT);i++){
    if(child.exitCode!==null)throw new Error('Core exited before verification')
    await sleep(100)
  }
  if(!existsSync(env.DITTO_G2_TEST_OUT))throw new Error('verification timed out')
  const result=JSON.parse(readFileSync(env.DITTO_G2_TEST_OUT,'utf8'))
  console.log(JSON.stringify({...result,evidence_class:process.env.DITTO_ENVIRONMENT_LABEL??'development-host',model_inference:false,quota_enforcement_measured:false}))
  if(!result.ok)throw new Error(result.error??'foundation checks failed')
}catch(error){
  // Core logs contain identifiers and phases, not tokens or provider payloads.
  console.error(readFileSync(root+'/core.log','utf8').slice(-12000));throw error
}finally{
  try{process.kill(-child.pid,'SIGTERM')}catch{}
  await sleep(200)
  try{process.kill(-child.pid,'SIGKILL')}catch{}
  // Package payloads are intentionally immutable; make only this private
  // test tree writable so it can be removed after all processes are fenced.
  function writable(path){if(statSync(path).isDirectory()){chmodSync(path,0o700);for(const name of readdirSync(path))writable(path+'/'+name)}else chmodSync(path,0o600)}
  writable(root);rmSync(root,{recursive:true,force:true})
}
