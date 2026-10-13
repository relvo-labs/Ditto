// G2-QA-03 (AT-10): what changes under a running Agent turn wins. The
// scripted model pauses between two steps while the test, as the person,
// commits a GUI change on the same entry, revokes a grant, or turns AI off.
// The Agent's later step must not overwrite, must not use the revoked
// grant, and must not act once AI is off. Development evidence only.
import {spawn} from 'node:child_process'
import {createHash} from 'node:crypto'
import {mkdtempSync,mkdirSync,openSync,closeSync,readFileSync,existsSync,rmSync,chmodSync,readdirSync,lstatSync,realpathSync,writeFileSync} from 'node:fs'
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

const root=mkdtempSync(tmpdir()+'/ditto-g2-races-')
const sync=root+'/sync';mkdirSync(sync)
const sleep=ms=>new Promise(r=>setTimeout(r,ms))
// The model reached `name` and waits until the test says go.
const pause=async name=>{
  writeFileSync(`${sync}/at-${name}`,'')
  for(let i=0;i<600&&!existsSync(`${sync}/go-${name}`);i++)await sleep(50)
}
const findEntry=(value,pkg)=>{
  if(!value||typeof value!=='object')return
  if(value.package===pkg&&typeof value.entry_id==='string')return value
  for(const child of Object.values(value)){const found=findEntry(child,pkg);if(found)return found}
}
const focusOn=profile=>{
  const entry=findEntry(profile,'ditto.svc.notification-policy')
  const after={...(entry.config??{}),rules:{...(entry.config?.rules??{}),focus:{enabled:true,allow:['agent']}}}
  return call('desktop__changes__propose',{base_revision:profile.profile.head_revision,ops:[{op:'set_entry_config',entry_id:entry.entry_id,after}]},'propose')
}
const provider=await startProvider(async body=>{
  const outputs=toolOutputs(body),text=userText(body)
  if(text.includes('race-base')){
    if(!outputs.has('read'))return [call('desktop__profiles__get',{},'read')]
    if(!outputs.has('propose')){await pause('base');return [focusOn(JSON.parse(outputs.get('read')))]}
    return [say(outputs.get('propose'))]
  }
  if(text.includes('race-grant')){
    if(!outputs.has('w1'))return [call('desktop__windows__list',{},'w1')]
    if(!outputs.has('w2')){await pause('grant');return [call('desktop__windows__list',{},'w2')]}
    return [say('done')]
  }
  if(text.includes('race-disable')){
    if(!outputs.has('read'))return [call('desktop__profiles__get',{},'read')]
    if(!outputs.has('propose')){await pause('disable');return [focusOn(JSON.parse(outputs.get('read')))]}
    return [say('done')]
  }
  return [say('unexpected request')]
})
const log=openSync(root+'/core.log','w')
const env={...process.env,DITTO_RUNTIME_DIR:root+'/run',DITTO_DATA_DIR:root+'/store',DITTO_SYSTEM:'none',DITTO_G2_TEST_OUT:root+'/result.json',DITTO_G2_SYNC:sync}
for(const key of ['DITTO_DEV_TOKEN','DITTO_LAUNCH_SCOPE_PREFIX','DITTO_REQUIRE_QUOTA','WAYFIRE_SOCKET','SWAYSOCK','DITTO_FAULT'])delete env[key]
const child=spawn(resolve(workspace,'target/debug/ditto-core'),['serve','--compositor','fixture',
  '--builtin-packages',resolve(workspace,'target/ditto-packages'),
  '--hostd',`hostd 0.2.0 ${process.execPath} ${resolve(workspace,'packages/host-runtime/dist/ditto-hostd.mjs')}`,
  '--agent',`agent 0.3.0 ${process.execPath} ${resolve(workspace,'packages/agent-runtime/dist/ditto-agentd.mjs')}`,
  '--agent-backend',`codex-app-server ${pin.version} ${pin.sha256} ${codex}`,
  '--agent-backend-test-provider',`http://127.0.0.1:${provider.port}/v1`,
  '--launch',`dittoctl 0.3.0 ${process.execPath} ${resolve(workspace,'tests/g2/codex/races-driver.mjs')}`,
],{env,stdio:['ignore',log,log],detached:true})
closeSync(log)
try{
  for(let i=0;i<3000&&!existsSync(env.DITTO_G2_TEST_OUT);i++){if(child.exitCode!==null)throw new Error('Core exited');await sleep(100)}
  if(!existsSync(env.DITTO_G2_TEST_OUT))throw new Error('timed out')
  const result=JSON.parse(readFileSync(env.DITTO_G2_TEST_OUT,'utf8'))
  if(!result.ok)throw new Error(result.error)
  console.log(JSON.stringify({...result,evidence_class:process.env.DITTO_ENVIRONMENT_LABEL??'development-host',model:'scripted-loopback'}))
}catch(error){
  console.error(readFileSync(root+'/core.log','utf8').slice(-8000))
  console.log(JSON.stringify({ok:false,error:String(error)}));process.exitCode=1
}finally{
  try{process.kill(-child.pid,'SIGTERM')}catch{}
  await sleep(300);try{process.kill(-child.pid,'SIGKILL')}catch{}
  await provider.close()
  function writable(p){const s=lstatSync(p);if(s.isSymbolicLink())return;if(s.isDirectory()){chmodSync(p,0o700);for(const n of readdirSync(p))writable(p+'/'+n)}else chmodSync(p,0o600)}
  writable(root);rmSync(root,{recursive:true,force:true})
}
