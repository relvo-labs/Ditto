// G2-AGENT-02 / CORE-04 / CORE-08: the replaceable direct-model path with an
// API key kept in the session's real Secret Service. The model is a scripted
// loopback Responses endpoint that checks the key it receives.
import {spawn} from 'node:child_process'
import {mkdtempSync,mkdirSync,openSync,closeSync,readFileSync,existsSync,rmSync,chmodSync,readdirSync,lstatSync,statSync} from 'node:fs'
import {tmpdir} from 'node:os'
import {resolve,join} from 'node:path'
import {fileURLToPath} from 'node:url'
import {startProvider,toolOutputs,userText,call,say} from '../codex/mock-provider.mjs'

const workspace=fileURLToPath(new URL('../../../',import.meta.url))
if(!process.env.DBUS_SESSION_BUS_ADDRESS){console.log(JSON.stringify({ok:false,not_run:'no session bus / Secret Service'}));process.exit(2)}
const key='sk-ditto-canary-'+Math.random().toString(36).slice(2)
const findEntry=(value,pkg)=>{if(!value||typeof value!=='object')return;if(value.package===pkg&&typeof value.entry_id==='string')return value;for(const c of Object.values(value)){const f=findEntry(c,pkg);if(f)return f}}
let wrongKey=0
const provider=await startProvider(body=>{
  const outputs=toolOutputs(body)
  if(!outputs.has('read-profile'))return [call('desktop__profiles__get',{},'read-profile')]
  if(!outputs.has('propose')){
    const profile=JSON.parse(outputs.get('read-profile'))
    const entry=findEntry(profile,'ditto.svc.notification-policy')
    return [call('desktop__changes__propose',{base_revision:profile.profile.head_revision,ops:[{op:'set_entry_config',entry_id:entry.entry_id,after:{...(entry.config??{}),rules:{...(entry.config?.rules??{}),focus:{enabled:true,allow:[]}}}}]},'propose')]
  }
  return [say(outputs.get('propose').includes('"committed"')?'已開啟專注模式。':'沒有完成。')]
})
const root=mkdtempSync(tmpdir()+'/ditto-g2-direct-')
mkdirSync(root+'/home')
const log=openSync(root+'/core.log','w')
const env={...process.env,HOME:root+'/home',DITTO_RUNTIME_DIR:root+'/run',DITTO_DATA_DIR:root+'/store',DITTO_SYSTEM:'none',DITTO_G2_TEST_OUT:root+'/result.json',DITTO_G2_KEY:key,DITTO_G2_ENDPOINT:`http://127.0.0.1:${provider.port}/v1`}
for(const k of ['DITTO_DEV_TOKEN','DITTO_LAUNCH_SCOPE_PREFIX','DITTO_REQUIRE_QUOTA','WAYFIRE_SOCKET','SWAYSOCK'])delete env[k]
const child=spawn(resolve(workspace,'target/debug/ditto-core'),['serve','--compositor','fixture',
  '--builtin-packages',resolve(workspace,'target/ditto-packages'),
  '--hostd',`hostd 0.2.0 ${process.execPath} ${resolve(workspace,'packages/host-runtime/dist/ditto-hostd.mjs')}`,
  '--agent',`agent 0.3.0 ${process.execPath} ${resolve(workspace,'packages/agent-runtime/dist/ditto-agentd.mjs')}`,
  '--launch',`dittoctl 0.3.0 ${process.execPath} ${resolve(workspace,'tests/g2/direct/driver.mjs')}`,
],{env,stdio:['ignore',log,log],detached:true})
closeSync(log)
const sleep=ms=>new Promise(r=>setTimeout(r,ms))
const checks=[]
const verify=(n,v)=>{if(!v)throw new Error('check failed: '+n);checks.push(n)}
function grep(path,needle){const found=[];const walk=p=>{const s=lstatSync(p);if(s.isSymbolicLink())return;if(s.isDirectory()){for(const n of readdirSync(p))walk(p+'/'+n)}else if(s.isFile()&&readFileSync(p).includes(needle))found.push(p)};if(existsSync(path))walk(path);return found}
try{
  for(let i=0;i<1800&&!existsSync(env.DITTO_G2_TEST_OUT);i++){if(child.exitCode!==null)throw new Error('Core exited');await sleep(100)}
  const result=JSON.parse(readFileSync(env.DITTO_G2_TEST_OUT,'utf8'))
  if(!result.ok)throw new Error(result.error)
  checks.push(...result.checks)
  const responses=provider.requests.filter(r=>r.url.endsWith('/responses'))
  verify('every model request carried the stored key, and only to the endpoint',responses.length>=3&&responses.every(r=>r.authorization==='Bearer '+key))
  const leaks=[...grep(root+'/store',key),...grep(root+'/run',key),...grep(root+'/home',key)]
  verify('the key is nowhere on disk in Ditto\'s state: '+JSON.stringify(leaks),leaks.length===0)
  verify('the key is in no Core log line',!readFileSync(root+'/core.log','utf8').includes(key))
  console.log(JSON.stringify({ok:true,checks,model:'scripted-loopback',evidence_class:'development-host',keyring:'session Secret Service'}))
}catch(error){console.error(readFileSync(root+'/core.log','utf8').slice(-6000));console.log(JSON.stringify({ok:false,checks,error:String(error)}));process.exitCode=1}
finally{
  try{process.kill(-child.pid,'SIGTERM')}catch{}
  await sleep(300);try{process.kill(-child.pid,'SIGKILL')}catch{}
  await provider.close()
  function writable(p){const s=lstatSync(p);if(s.isSymbolicLink())return;if(s.isDirectory()){chmodSync(p,0o700);for(const n of readdirSync(p))writable(p+'/'+n)}else chmodSync(p,0o600)}
  writable(root);rmSync(root,{recursive:true,force:true})
}
