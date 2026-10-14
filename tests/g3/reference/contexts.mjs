// Actual missing dependencies and a separately compiled fixed-fault host.
// No fake reports, forged full attestation or arbitrary candidate QML.
import {createConnection} from 'node:net'
import {readFileSync,writeFileSync} from 'node:fs'
import {execFileSync} from 'node:child_process'
import {trustMatrix} from '../integration/trust-matrix.mjs'
const mode=process.env.DITTO_G3_REFERENCE_MODE,run=process.env.DITTO_G3_RUN_SUFFIX,checks=[],facts={mode}
const line=(path,text)=>new Promise((resolve,reject)=>{const s=createConnection(path);let b='';const t=setTimeout(()=>{s.destroy();reject(Error('relay timeout'))},90000);s.on('error',e=>{clearTimeout(t);reject(e)});s.on('connect',()=>s.write(text+'\n'));s.on('data',d=>{b+=d;if(b.includes('\n')){clearTimeout(t);s.destroy();resolve(JSON.parse(b.split('\n')[0]))}})})
const call=(method,params={})=>line(process.env.DITTO_G1_RELAY,JSON.stringify({method,params}))
const must=async(method,params)=>{const r=await call(method,params);if(r.error)throw Error(method+': '+JSON.stringify(r.error));return r.result}
const verify=(name,yes)=>{if(!yes)throw Error(name);checks.push(name);console.log('PASS '+name)}
const shell=text=>line(process.env.DITTO_RUNTIME_DIR+'/shell.sock',text)
const snapshot=()=>JSON.parse(execFileSync('python3',['-c',"import sys,json;sys.path.insert(0,'tests/g3/reference');import observe;print(json.dumps(observe.snapshot()))"],{encoding:'utf8'}))
const sleep=ms=>new Promise(r=>setTimeout(r,ms))
try{
 const before=snapshot();facts.before=before
 for(const kind of mode==='faults'?['syntax','illegal-import','timeout']:[mode]){
  if(mode==='faults')writeFileSync(process.env.DITTO_BINARIES+'/generation-fault.txt',kind)
  const description=JSON.parse(readFileSync('crates/ditto-generation/examples/tasks-summary.json','utf8'));description.plugin_id+='.'+run+'.'+kind.replaceAll('-','_');description.title='實體負例 '+kind
  const artifact=await must('desktop.plugins.development.create',{description,request_summary:'Trusted physical fixture: '+kind,idempotency_key:run+kind})
  const started=await call('desktop.plugins.development.validate',{artifact_id:artifact.artifact_id,idempotency_key:run+kind})
  if(mode==='unavailable')verify('missing actual native helper refuses execution',started.error?.name==='unavailable')
  else {
   if(started.error)throw Error(JSON.stringify(started.error))
   let job
   for(let i=0;i<400;i++){job=await must('desktop.jobs.get',{job_id:started.result.job_id});if(['succeeded','failed','cancelled'].includes(job.state))break;await sleep(100)}
   facts[kind+'-job']=job
  }
  const observed=await must('desktop.plugins.development.get',{artifact_id:artifact.artifact_id});facts[kind]=observed
  if(mode==='partial')verify('missing Qt allowlist is actually partial and inspect only',observed.state==='inspect_only'&&observed.validation.boundary.enforcement==='partial'&&observed.validation.stages.every(s=>s.result==='not_run'))
  if(mode==='faults')verify(kind+' reports the actual first failure',observed.state==='failed'&&observed.validation.boundary.enforcement==='full'&&observed.validation.stages[0].result==='failed'&&observed.validation.stages.slice(1).every(s=>s.result==='not_run'))
  verify(kind+' cannot publish',(await call('desktop.plugins.development.publish',{artifact_id:artifact.artifact_id})).error)
  const after=snapshot();facts[kind+'-after']=after
  for(const key of ['core','shell','hostd','wayfire','native_application','revision'])verify(kind+' preserves '+key,JSON.stringify(before[key])===JSON.stringify(after[key]))
 }
 if(mode!=='faults')facts.trust=await trustMatrix({call,must},before.revision,verify)
 // Open the actual management window and navigate to a failure/inspection
 // action by Tab. The input is delivered by Wayfire, never by RPC.
 const socket=createConnection(process.env.DITTO_RUNTIME_DIR+'/shell.sock');await new Promise((yes,no)=>{socket.on('error',no);socket.on('connect',()=>{socket.end('command plugins.open\n');yes()})});await sleep(700)
 facts.management=await shell('generation-management')
 if(mode==='faults')verify('actual management shows failure and next step',facts.management.some(r=>r.visible&&r.name.startsWith('generationState_')&&r.text.includes('請檢查診斷並建立修正版'))&&facts.management.some(r=>r.visible&&r.name.startsWith('generationStage_')&&r.text.includes('未通過')))
 const name=mode==='faults'?'原始碼、驗證與啟用紀錄':'驗證'
 facts.keyboard=execFileSync('python3',['tests/g1/lib/gui.py','tab-to',name],{encoding:'utf8'})
 execFileSync('grim',[process.env.DITTO_ARTIFACTS+'/management.png'])
 execFileSync('python3',['tests/g1/lib/gui.py','key','KEY_ESC'])
}catch(error){facts.error=String(error);process.exitCode=1;console.error(error)}
finally{writeFileSync(process.env.DITTO_G3_TEST_OUT,JSON.stringify({ok:!process.exitCode,evidence_class:'reference-physical-seat',checks,facts},null,2)+'\n')}
