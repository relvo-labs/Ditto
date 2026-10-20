// G2-CORE-05 / AGENT-11 on a development host: Core's job pool with real
// systemd user scopes (D-06b short-tool quota). Fixture kinds stand in for
// heavy work; packages.verify is the real trusted kind.
import {spawn,execFileSync} from 'node:child_process'
import {mkdtempSync,openSync,closeSync,readFileSync,existsSync,rmSync,chmodSync,readdirSync,lstatSync} from 'node:fs'
import {tmpdir} from 'node:os'
import {resolve} from 'node:path'
import {fileURLToPath} from 'node:url'

const workspace=fileURLToPath(new URL('../../../',import.meta.url))
const root=mkdtempSync(tmpdir()+'/ditto-g2-jobs-')
const log=openSync(root+'/core.log','w')
const env={...process.env,DITTO_RUNTIME_DIR:root+'/run',DITTO_DATA_DIR:root+'/store',DITTO_SYSTEM:'none',DITTO_G2_TEST_OUT:root+'/result.json',DITTO_G2_ROOT:root}
for(const key of ['DITTO_DEV_TOKEN','DITTO_LAUNCH_SCOPE_PREFIX','DITTO_REQUIRE_QUOTA','WAYFIRE_SOCKET','SWAYSOCK'])delete env[key]
const child=spawn(resolve(workspace,'target/debug/ditto-core'),['serve','--compositor','fixture',
  '--builtin-packages',resolve(workspace,'target/ditto-packages'),
  '--hostd',`hostd 0.2.0 ${process.execPath} ${resolve(workspace,'packages/host-runtime/dist/ditto-hostd.mjs')}`,
  '--launch',`dittoctl 0.3.0 ${process.execPath} ${resolve(workspace,'tests/g2/jobs/driver.mjs')}`,
],{env,stdio:['ignore',log,log],detached:true})
closeSync(log)
const sleep=ms=>new Promise(r=>setTimeout(r,ms))
try{
  for(let i=0;i<1800&&!existsSync(env.DITTO_G2_TEST_OUT);i++){if(child.exitCode!==null)throw new Error('Core exited');await sleep(100)}
  const result=JSON.parse(readFileSync(env.DITTO_G2_TEST_OUT,'utf8'))
  console.log(JSON.stringify({...result,evidence_class:process.env.DITTO_ENVIRONMENT_LABEL??'development-host'}))
  if(!result.ok){console.error(readFileSync(root+'/core.log','utf8').slice(-5000));process.exitCode=1}
}catch(error){console.error(readFileSync(root+'/core.log','utf8').slice(-5000));console.log(JSON.stringify({ok:false,error:String(error)}));process.exitCode=1}
finally{
  try{process.kill(-child.pid,'SIGTERM')}catch{}
  await sleep(300);try{process.kill(-child.pid,'SIGKILL')}catch{}
  // Only the job scopes this run's Core created (driver.mjs lists them): a
  // ditto-job-* glob would also stop a logged-in session's jobs (#124).
  const own=existsSync(root+'/job-scopes')?[...new Set(readFileSync(root+'/job-scopes','utf8').split('\n').filter(Boolean))]:[]
  if(own.length)try{execFileSync('systemctl',['--user','stop',...own],{stdio:'ignore'})}catch{}
  function writable(p){const s=lstatSync(p);if(s.isSymbolicLink())return;if(s.isDirectory()){chmodSync(p,0o700);for(const n of readdirSync(p))writable(p+'/'+n)}else chmodSync(p,0o600)}
  writable(root);rmSync(root,{recursive:true,force:true})
}
