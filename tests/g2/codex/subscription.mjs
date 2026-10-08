// G2 M1 with the real Codex subscription (development host). Core (fixture
// compositor) launches the pinned app-server confined, with the user's
// Secret Service behind the filtered proxy. The person running this signs in
// in their own browser when asked; the token stays in the keyring and never
// passes through this script. One real model turn then changes a desktop
// setting, which Core reads back and undoes.
//
// State persists in DITTO_G2_SUBSCRIPTION_DIR (default ~/.cache/ditto-g2-
// subscription) so a later run reuses the sign-in (the keyring entry is
// keyed by that private CODEX_HOME path). Nothing from the account is printed
// except what Ditto's own status shows: model ids, quota percentages.
import {spawn} from 'node:child_process'
import {createHash} from 'node:crypto'
import {mkdirSync,openSync,closeSync,readFileSync,existsSync,writeFileSync,realpathSync,rmSync} from 'node:fs'
import {homedir} from 'node:os'
import {resolve,join} from 'node:path'
import {fileURLToPath} from 'node:url'

const workspace=fileURLToPath(new URL('../../../',import.meta.url))
const pin=JSON.parse(readFileSync(resolve(workspace,'tools/codex/pin.json'),'utf8'))
const codex=realpathSync(process.env.DITTO_CODEX_BINARY??join(homedir(),'.local/bin/codex'))
if(createHash('sha256').update(readFileSync(codex)).digest('hex')!==pin.sha256)throw new Error('installed Codex binary differs from tools/codex/pin.json')
if(!process.env.DBUS_SESSION_BUS_ADDRESS)throw new Error('a session bus with a Secret Service is required')
const root=process.env.DITTO_G2_SUBSCRIPTION_DIR??join(homedir(),'.cache/ditto-g2-subscription')
const run=join(root,'run-'+Date.now())
mkdirSync(run,{recursive:true,mode:0o700})
const out=join(run,'result.json'),loginFile=join(run,'login.json')
const log=openSync(join(run,'core.log'),'w')
const env={...process.env,DITTO_G2_LOGIN_WAIT_MIN:process.env.DITTO_G2_LOGIN_WAIT_MIN??'15',DITTO_RUNTIME_DIR:join(run,'rt'),DITTO_DATA_DIR:join(root,'store'),DITTO_SYSTEM:'none',DITTO_G2_TEST_OUT:out,DITTO_G2_LOGIN_FILE:loginFile,DITTO_G2_TASK:process.env.DITTO_G2_TASK??'focus'}
for(const key of ['DITTO_DEV_TOKEN','DITTO_LAUNCH_SCOPE_PREFIX','DITTO_REQUIRE_QUOTA','WAYFIRE_SOCKET','SWAYSOCK'])delete env[key]
const child=spawn(resolve(workspace,'target/debug/ditto-core'),['serve','--compositor','fixture',
  '--builtin-packages',resolve(workspace,'target/ditto-packages'),
  '--hostd',`hostd 0.2.0 ${process.execPath} ${resolve(workspace,'packages/host-runtime/dist/ditto-hostd.mjs')}`,
  '--agent',`agent 0.3.0 ${process.execPath} ${resolve(workspace,'packages/agent-runtime/dist/ditto-agentd.mjs')}`,
  '--agent-backend',`codex-app-server ${pin.version} ${pin.sha256} ${codex}`,
  '--launch',`dittoctl 0.3.0 ${process.execPath} ${resolve(workspace,'tests/g2/codex/subscription-driver.mjs')}`,
],{env,stdio:['ignore',log,log],detached:true})
closeSync(log)
const sleep=ms=>new Promise(r=>setTimeout(r,ms))
let announced=false
try{
  const waitMinutes=Number(process.env.DITTO_G2_LOGIN_WAIT_MIN??15)
  for(let i=0;i<(waitMinutes+5)*60*10&&!existsSync(out);i++){
    if(child.exitCode!==null)throw new Error('Core exited')
    if(!announced&&existsSync(loginFile)){
      announced=true
      const login=JSON.parse(readFileSync(loginFile,'utf8'))
      if(process.env.DITTO_G2_OPEN_BROWSER)spawn('xdg-open',[login.auth_url],{stdio:'ignore',detached:true}).unref()
      console.log('SIGN-IN REQUIRED: open this address in your browser and sign in with your ChatGPT account:\n'+login.auth_url+`\n(waiting up to ${waitMinutes} minutes)`)
    }
    await sleep(100)
  }
  if(!existsSync(out))throw new Error('timed out')
  const result=JSON.parse(readFileSync(out,'utf8'))
  console.log(JSON.stringify({...result,evidence_class:'development-host-real-subscription',codex_version:pin.version}))
  if(!result.ok)process.exitCode=1
}catch(error){
  console.error(readFileSync(join(run,'core.log'),'utf8').slice(-8000))
  console.log(JSON.stringify({ok:false,error:String(error)}));process.exitCode=1
}finally{
  try{process.kill(-child.pid,'SIGTERM')}catch{}
  await sleep(500)
  try{process.kill(-child.pid,'SIGKILL')}catch{}
  rmSync(join(run,'rt'),{recursive:true,force:true})
}
