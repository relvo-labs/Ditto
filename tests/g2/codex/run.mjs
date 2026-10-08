// G2 M1 plumbing, end to end on a development host: Core (fixture
// compositor) → Agent controller → Codex app-server 0.160.0 inside
// ditto-confine → a scripted loopback model → Ditto dynamic tools → Core
// ChangeSet → readback → undo. The model is scripted, so this proves the
// path and its boundaries, never model quality or subscription access.
import {spawn} from 'node:child_process'
import {createHash} from 'node:crypto'
import {mkdtempSync,openSync,closeSync,readFileSync,existsSync,rmSync,chmodSync,readdirSync,statSync,realpathSync} from 'node:fs'
import {tmpdir,homedir} from 'node:os'
import {resolve,join} from 'node:path'
import {fileURLToPath} from 'node:url'
import {startProvider,toolOutputs,userText,call,say} from './mock-provider.mjs'

const workspace=fileURLToPath(new URL('../../../',import.meta.url))
const pin=JSON.parse(readFileSync(resolve(workspace,'tools/codex/pin.json'),'utf8'))
const candidate=process.env.DITTO_CODEX_BINARY??join(homedir(),'.local/bin/codex')
if(!existsSync(candidate)){console.log(JSON.stringify({ok:false,not_run:'pinned Codex binary not installed'}));process.exit(2)}
const codex=realpathSync(candidate)
const sha=createHash('sha256').update(readFileSync(codex)).digest('hex')
if(sha!==pin.sha256){console.log(JSON.stringify({ok:false,not_run:'installed Codex binary differs from tools/codex/pin.json'}));process.exit(2)}

const canary='ditto-canary-'+Math.random().toString(36).slice(2)
// The scripted model: try two disabled built-ins, read the profile, turn on
// the notification policy's focus rule on the head revision (a hostd-backed
// plugin config, so the fixture needs no Shell), then report. Each step
// reacts to real tool output, so a refused or failed call fails the scenario.
const findEntry=(value,pkg)=>{
  if(!value||typeof value!=='object')return
  if(value.package===pkg&&typeof value.entry_id==='string')return value
  for(const child of Object.values(value)){const found=findEntry(child,pkg);if(found)return found}
}
const provider=await startProvider(body=>{
  const outputs=toolOutputs(body)
  if(userText(body).includes('follow-up'))return [say('好的。')]
  if(!userText(body).includes(canary))return [say('unexpected request')]
  if(!outputs.has('read-profile'))return [
    call('exec_command',{cmd:'touch /tmp/ditto-g2-escape'},'builtin-exec'),
    call('web_search',{query:'x'},'builtin-search'),
    call('desktop__profiles__get',{},'read-profile'),
  ]
  if(!outputs.has('propose')){
    const profile=JSON.parse(outputs.get('read-profile'))
    const entry=findEntry(profile,'ditto.svc.notification-policy')
    if(!entry)return [say('找不到通知規則插件。')]
    const after={...(entry.config??{}),rules:{...(entry.config?.rules??{}),focus:{enabled:true,allow:[]}}}
    return [call('desktop__changes__propose',{base_revision:profile.profile.head_revision,ops:[{op:'set_entry_config',entry_id:entry.entry_id,after}]},'propose')]
  }
  const result=JSON.parse(outputs.get('propose'))
  return [say(JSON.stringify(result).includes('"committed"')?'已開啟通知專注模式。':'變更沒有完成。')]
})

const root=mkdtempSync(tmpdir()+'/ditto-g2-codex-')
const log=openSync(root+'/core.log','w')
const env={...process.env,DITTO_RUNTIME_DIR:root+'/run',DITTO_DATA_DIR:root+'/store',DITTO_SYSTEM:'none',DITTO_G2_TEST_OUT:root+'/result.json',DITTO_G2_CANARY:canary}
for(const key of ['DITTO_DEV_TOKEN','DITTO_LAUNCH_SCOPE_PREFIX','DITTO_REQUIRE_QUOTA','WAYFIRE_SOCKET','SWAYSOCK'])delete env[key]
const child=spawn(resolve(workspace,'target/debug/ditto-core'),['serve','--compositor','fixture',
  '--builtin-packages',resolve(workspace,'target/ditto-packages'),
  '--hostd',`hostd 0.2.0 ${process.execPath} ${resolve(workspace,'packages/host-runtime/dist/ditto-hostd.mjs')}`,
  '--agent',`agent 0.3.0 ${process.execPath} ${resolve(workspace,'packages/agent-runtime/dist/ditto-agentd.mjs')}`,
  '--agent-backend',`codex-app-server ${pin.version} ${pin.sha256} ${codex}`,
  '--agent-backend-test-provider',`http://127.0.0.1:${provider.port}/v1`,
  '--launch',`dittoctl 0.3.0 ${process.execPath} ${resolve(workspace,'tests/g2/codex/driver.mjs')}`,
],{env,stdio:['ignore',log,log],detached:true})
closeSync(log)
const sleep=ms=>new Promise(resolve=>setTimeout(resolve,ms))
const checks=[]
const verify=(name,value)=>{if(!value)throw new Error('check failed: '+name);checks.push(name)}
function grep(path,needle){
  if(!existsSync(path))return []
  const found=[]
  const walk=p=>{const s=statSync(p);if(s.isDirectory()){for(const n of readdirSync(p))walk(p+'/'+n)}else if(s.isFile()&&readFileSync(p).includes(needle))found.push(p)}
  walk(path);return found
}
try{
  for(let i=0;i<1200&&!existsSync(env.DITTO_G2_TEST_OUT);i++){
    if(child.exitCode!==null)throw new Error('Core exited before verification')
    await sleep(100)
  }
  if(!existsSync(env.DITTO_G2_TEST_OUT))throw new Error('verification timed out')
  const result=JSON.parse(readFileSync(env.DITTO_G2_TEST_OUT,'utf8'))
  if(!result.ok)throw new Error(result.error??'driver checks failed')
  checks.push(...result.checks)
  const sent=provider.requests.filter(r=>r.url.endsWith('/responses')).map(r=>r.body)
  if(process.env.DITTO_G2_DUMP)(await import('node:fs')).writeFileSync(process.env.DITTO_G2_DUMP,JSON.stringify(sent,null,1))
  // Tools reach the model either as `tools` or, for current model families,
  // inside an `additional_tools` input item, possibly nested in namespaces.
  const flatten=(tools,prefix='')=>(tools??[]).flatMap(t=>t.tools?flatten(t.tools,t.name==='functions'?'':(t.name??'')+'.'):[prefix+(t.name??t.type)])
  const names=new Set(sent.flatMap(b=>[...flatten(b.tools),...(b.input??[]).filter(i=>i.type==='additional_tools').flatMap(i=>flatten(i.tools))]))
  verify('model saw Ditto tools: '+JSON.stringify([...names]),names.has('desktop__changes__propose')&&names.has('desktop__profiles__get'))
  // request_user_input* are refused by Ditto's adapter as server requests.
  const builtins=[...names].filter(n=>!n.startsWith('desktop__')&&!n.startsWith('request_user_input'))
  verify('no built-in Codex tool offered to the model: '+JSON.stringify(builtins),builtins.length===0)
  const last=toolOutputs(sent.filter(b=>toolOutputs(b).has('builtin-exec')).at(-1))
  verify('built-in exec refused by backend',/unsupported call/.test(last.get('builtin-exec')??''))
  verify('built-in search refused by backend',/unsupported call/.test(last.get('builtin-search')??''))
  verify('no file escaped the boundary',!existsSync('/tmp/ditto-g2-escape'))
  const leaks=grep(join(root,'store'),canary).filter(p=>!p.includes('/conversations/'))
  verify('canary only in Core conversation store: '+JSON.stringify(leaks),leaks.length===0)
  const followUp=sent.find(b=>userText(b).includes('follow-up'))
  verify('a follow-up turn carries the verified change it can refer to',!!followUp&&JSON.stringify(followUp.input).includes(result.change_id)&&JSON.stringify(followUp.input).includes('Recent verified changes'))
  const pss=existsSync(env.DITTO_G2_TEST_OUT+'.pss')?JSON.parse(readFileSync(env.DITTO_G2_TEST_OUT+'.pss','utf8')):null
  console.log(JSON.stringify({ok:true,checks,warm_pss_kib_development:pss,model_requests:sent.length,codex_version:pin.version,evidence_class:process.env.DITTO_ENVIRONMENT_LABEL??'development-host',model:'scripted-loopback',subscription:false}))
}catch(error){
  console.error(readFileSync(root+'/core.log','utf8').slice(-12000))
  const backendLog=grep(join(root,'store'),'').find(p=>p.endsWith('backend.log'))
  if(backendLog)console.error(readFileSync(backendLog,'utf8').slice(-4000))
  console.log(JSON.stringify({ok:false,checks,error:String(error)}));process.exitCode=1
}finally{
  try{process.kill(-child.pid,'SIGTERM')}catch{}
  await sleep(300)
  try{process.kill(-child.pid,'SIGKILL')}catch{}
  await provider.close()
  function writable(path){if(statSync(path).isDirectory()){chmodSync(path,0o700);for(const name of readdirSync(path))writable(path+'/'+name)}else chmodSync(path,0o600)}
  if(process.env.DITTO_G2_KEEP)console.error('kept '+root)
  else{writable(root);rmSync(root,{recursive:true,force:true})}
}
