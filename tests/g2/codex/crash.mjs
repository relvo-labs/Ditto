// G2-AGENT-10 / CHG-07: Core is killed (fault point) while an Agent tool's
// ChangeSet is applying or verifying. On the next start, boot recovery
// decides the ChangeSet, the lost tool result is settled from it, the turn
// is `unknown`, and the next Agent generation neither replays the call nor
// sends it to the model as a pending request. Needs a fault-injection Core:
//   cargo build -p ditto-core -p ditto-confine --features ditto-core/fault-injection --target-dir target/fault-injection
import {spawn} from 'node:child_process'
import {createHash} from 'node:crypto'
import {mkdtempSync,openSync,closeSync,readFileSync,existsSync,rmSync,chmodSync,readdirSync,lstatSync,realpathSync,copyFileSync} from 'node:fs'
import {tmpdir,homedir} from 'node:os'
import {resolve,join} from 'node:path'
import {fileURLToPath} from 'node:url'
import {startProvider,toolOutputs,userText,call,say} from './mock-provider.mjs'
import {exitUnlessConfinable} from '../lib/environment.mjs'
exitUnlessConfinable()

const workspace=fileURLToPath(new URL('../../../',import.meta.url))
const pin=JSON.parse(readFileSync(resolve(workspace,'tools/codex/pin.json'),'utf8'))
const candidate=process.env.DITTO_CODEX_BINARY??join(homedir(),'.local/bin/codex')
if(!existsSync(candidate)){console.log(JSON.stringify({ok:false,not_run:'pinned Codex binary not installed'}));process.exit(2)}
const codex=realpathSync(candidate)
if(createHash('sha256').update(readFileSync(codex)).digest('hex')!==pin.sha256){console.log(JSON.stringify({ok:false,not_run:'Codex binary differs from pin'}));process.exit(2)}
const bin=resolve(workspace,'target/fault-injection/debug')
if(!existsSync(bin+'/ditto-core')||!existsSync(bin+'/ditto-confine')){console.log(JSON.stringify({ok:false,not_run:'no fault-injection build in target/fault-injection'}));process.exit(2)}
if(existsSync(resolve(workspace,'target/debug/ditto-dbus-proxy')))copyFileSync(resolve(workspace,'target/debug/ditto-dbus-proxy'),bin+'/ditto-dbus-proxy')

const findEntry=(value,pkg)=>{
  if(!value||typeof value!=='object')return
  if(value.package===pkg&&typeof value.entry_id==='string')return value
  for(const child of Object.values(value)){const found=findEntry(child,pkg);if(found)return found}
}
const provider=await startProvider(body=>{
  const outputs=toolOutputs(body)
  if(userText(body).includes('follow-up'))return [say('好的。')]
  if(!userText(body).includes('crash:'))return [say('unexpected request')]
  if(!outputs.has('read'))return [call('desktop__profiles__get',{},'read')]
  if(!outputs.has('propose')){
    const profile=JSON.parse(outputs.get('read'))
    const entry=findEntry(profile,'ditto.svc.notification-policy')
    const after={...(entry.config??{}),rules:{...(entry.config?.rules??{}),focus:{enabled:true,allow:[]}}}
    return [call('desktop__changes__propose',{base_revision:profile.profile.head_revision,ops:[{op:'set_entry_config',entry_id:entry.entry_id,after}]},'propose')]
  }
  return [say('done')]
})
const sleep=ms=>new Promise(r=>setTimeout(r,ms))
const results=[]
let failed=false
for(const state of ['applying','verifying']){
  const root=mkdtempSync(tmpdir()+'/ditto-g2-crash-')
  const env={...process.env,DITTO_RUNTIME_DIR:root+'/run',DITTO_DATA_DIR:root+'/store',DITTO_SYSTEM:'none',DITTO_G2_TEST_OUT:root+'/result.json'}
  for(const key of ['DITTO_DEV_TOKEN','DITTO_LAUNCH_SCOPE_PREFIX','DITTO_REQUIRE_QUOTA','WAYFIRE_SOCKET','SWAYSOCK','DITTO_FAULT'])delete env[key]
  const start=(phase,fault)=>{
    const log=openSync(`${root}/core-${phase}.log`,'w')
    const child=spawn(bin+'/ditto-core',['serve','--compositor','fixture',
      '--builtin-packages',resolve(workspace,'target/ditto-packages'),
      '--hostd',`hostd 0.2.0 ${process.execPath} ${resolve(workspace,'packages/host-runtime/dist/ditto-hostd.mjs')}`,
      '--agent',`agent 0.3.0 ${process.execPath} ${resolve(workspace,'packages/agent-runtime/dist/ditto-agentd.mjs')}`,
      '--agent-backend',`codex-app-server ${pin.version} ${pin.sha256} ${codex}`,
      '--agent-backend-test-provider',`http://127.0.0.1:${provider.port}/v1`,
      '--launch',`dittoctl 0.3.0 ${process.execPath} ${resolve(workspace,'tests/g2/codex/crash-driver.mjs')}`,
    ],{env:{...env,DITTO_G2_PHASE:phase,...(fault?{DITTO_FAULT:fault}:{})},stdio:['ignore',log,log],detached:true})
    closeSync(log)
    return child
  }
  const stop=async child=>{try{process.kill(-child.pid,'SIGKILL')}catch{};await sleep(300)}
  const requestsBefore=provider.requests.length
  let second
  try{
    const first=start('first',`coordinator.after_state=${state}:abort_process:1`)
    for(let i=0;i<1200&&first.exitCode===null&&first.signalCode===null;i++)await sleep(100)
    if(first.exitCode===null&&first.signalCode===null)throw new Error('Core did not reach the fault point')
    // What a crashed unit leaves behind is the service manager's to kill.
    await stop(first)
    second=start('second')
    for(let i=0;i<1800&&!existsSync(env.DITTO_G2_TEST_OUT);i++){if(second.exitCode!==null)throw new Error('Core exited');await sleep(100)}
    if(!existsSync(env.DITTO_G2_TEST_OUT))throw new Error('timed out')
    const result=JSON.parse(readFileSync(env.DITTO_G2_TEST_OUT,'utf8'))
    if(!result.ok)throw new Error(result.error)
    const sent=provider.requests.slice(requestsBefore).filter(r=>r.url.endsWith('/responses')).map(r=>r.body)
    const follow=sent.filter(b=>userText(b).includes('follow-up'))
    const replayed=follow.some(b=>(b.input??[]).some(i=>i.type==='function_call'||i.type==='function_call_output'))
    const checks=[...result.checks]
    // Which outcome recovery decides is the G1 coordinator's (here a
    // hostd-held entry whose host died with Core); this suite checks that the
    // Agent side reports exactly that and never acts on it again.
    if(!['committed','rolled_back','aborted','partially_applied','unknown'].includes(result.change_state))throw new Error(`${state}: change left in ${result.change_state}`)
    if(!follow.length||replayed)throw new Error('the follow-up request replayed earlier tool calls')
    checks.push('the follow-up carried no earlier tool call or result as a request')
    results.push({fault:state,ok:true,checks,recovery_decided:result.change_state,tool_outcome:result.outcome})
  }catch(error){
    failed=true
    for(const phase of ['first','second'])if(existsSync(`${root}/core-${phase}.log`))console.error(`--- ${phase}\n`+readFileSync(`${root}/core-${phase}.log`,'utf8').slice(-5000))
    results.push({fault:state,ok:false,error:String(error)})
  }finally{
    if(second)await stop(second)
    function writable(p){const s=lstatSync(p);if(s.isSymbolicLink())return;if(s.isDirectory()){chmodSync(p,0o700);for(const n of readdirSync(p))writable(p+'/'+n)}else chmodSync(p,0o600)}
    writable(root);rmSync(root,{recursive:true,force:true})
  }
}
await provider.close()
console.log(JSON.stringify({ok:!failed,results,evidence_class:process.env.DITTO_ENVIRONMENT_LABEL??'development-host',model:'scripted-loopback'}))
process.exitCode=failed?1:0
