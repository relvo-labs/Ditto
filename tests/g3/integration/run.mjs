import {execFileSync} from 'node:child_process'
// Production Core → durable job pool → real confined Qt runner. This fixture
// has no Shell, so activation is expected to abort without changing its head.
import {spawn} from 'node:child_process'
import {mkdtempSync,mkdirSync,openSync,closeSync,readFileSync,existsSync} from 'node:fs'
import {resolve} from 'node:path'
const workspace=resolve(import.meta.dirname,'../../..')
mkdirSync(workspace+'/artifacts/g3',{recursive:true})
const root=mkdtempSync(workspace+'/artifacts/g3/integration-')
const log=openSync(root+'/core.log','w')
const env={...process.env,XDG_RUNTIME_DIR:process.env.XDG_RUNTIME_DIR??'/run/user/'+process.getuid(),DITTO_RUNTIME_DIR:root+'/run',DITTO_DATA_DIR:root+'/store',DITTO_SYSTEM:'none',DITTO_G3_TEST_OUT:root+'/result.json'}
for(const key of ['DITTO_DEV_TOKEN','DITTO_LAUNCH_SCOPE_PREFIX','DITTO_REQUIRE_QUOTA','WAYFIRE_SOCKET','SWAYSOCK'])delete env[key]
const binaries=process.env.DITTO_BINARIES??workspace+'/target/debug'
const driver=process.env.DITTO_G3_FIXED_FAILURES==='1'?'failures-driver.mjs':'driver.mjs'
const child=spawn(binaries+'/ditto-core',['serve','--compositor','fixture','--launch',`dittoctl 0.3.0 ${process.execPath} ${workspace}/tests/g3/integration/${driver}`],{cwd:workspace,env,stdio:['ignore',log,log],detached:true})
closeSync(log)
const sleep=ms=>new Promise(r=>setTimeout(r,ms))
try{
  for(let i=0;i<900&&!existsSync(env.DITTO_G3_TEST_OUT);i++){if(child.exitCode!==null)throw new Error('Core exited');await sleep(100)}
  const result=JSON.parse(readFileSync(env.DITTO_G3_TEST_OUT,'utf8'))
  console.log(JSON.stringify({...result,source:JSON.parse(execFileSync("python3",[workspace+"/tests/g3/source.py"])),facts:Object.fromEntries(Object.entries(result.facts??{}).map(([k,v])=>[k,k.endsWith('-artifact')?{artifact_id:v.artifact_id,state:v.state,validation:v.validation}:v.job_id?{job_id:v.job_id,state:v.state,error_key:v.error_key,result:v.result}:v])),evidence_class:process.env.DITTO_ENVIRONMENT_LABEL??'development-host',evidence_path:root,model_inference:false}))
  if(!result.ok)throw new Error(result.error)
}catch(error){console.error(readFileSync(root+'/core.log','utf8').slice(-5000));throw error}
finally{
  try{process.kill(-child.pid,'SIGTERM')}catch{}
  await sleep(300)
  try{process.kill(-child.pid,'SIGKILL')}catch{}
  // This is a stopped, private fixture store retained as evidence. Keep the
  // production immutable modes during the test, then allow its owner (and the
  // next CI checkout) to remove the copy without deleting the evidence here.
  if(existsSync(root+'/store'))execFileSync('chmod',['-R','u+rwX',root+'/store'])
}
