// Real model oracle. Fixture Profile, natural requests, real Core readback.
import {createConnection} from 'node:net'
import {writeFileSync} from 'node:fs'
import {execFileSync} from 'node:child_process'
const checks=[],facts={source:JSON.parse(execFileSync('python3',['tests/g3/source.py']))},sleep=ms=>new Promise(r=>setTimeout(r,ms)),run=Date.now().toString()
const call=(method,params={})=>new Promise((resolve,reject)=>{const socket=createConnection(process.env.DITTO_G1_RELAY),timer=setTimeout(()=>{socket.destroy();reject(new Error('relay timeout'))},60000);let buffer='';socket.on('connect',()=>socket.write(JSON.stringify({method,params})+'\n'));socket.on('error',reject);socket.on('data',data=>{buffer+=data;if(buffer.includes('\n')){clearTimeout(timer);socket.destroy();resolve(JSON.parse(buffer.split('\n')[0]))}})})
const must=async(method,params)=>{const r=await call(method,params);if(r.error)throw new Error(method+': '+JSON.stringify(r.error));return r.result}
const verify=(name,yes)=>{if(!yes)throw new Error(name);checks.push(name);console.log('PASS '+name)}
const eventually=async(fn,tries=600)=>{for(let i=0;i<tries;i++){const v=await fn();if(v)return v;await sleep(500)}throw new Error('condition timed out')}
let original,preferences
const createdGrants=[]
try{
 await eventually(async()=>{const r=await call('desktop.profiles.get');return r.result})
 original=(await must('desktop.profiles.get')).profile;preferences=await must('agent.settings.describe')
 const {_meta,...s}=preferences
 await must('agent.settings.patch',{expected_revision:s.revision,settings:{...s,enabled:true,max_tool_calls:24,turn_timeout_ms:120000}})
 await must('agent.runtime.ensure');await eventually(async()=>(await must('agent.runtime.get')).phase==='ready',120)
 const status=await must('agent.providers.status',{provider:'codex-app-server'})
 if(!status.authenticated){facts.not_run='Existing test account is not signed in; no model request sent';process.exitCode=2}
 else {
  verify('existing test subscription authenticated',true)
  await must('desktop.profiles.create',{name:'G3 real-model '+run,from:'default',idempotency_key:'g3-real-profile-'+run})
  const p=(await must('desktop.profiles.list')).profiles.find(p=>p.name==='G3 real-model '+run)
  await must('desktop.changes.propose',{base_revision:original.head_revision,ops:[{op:'switch_profile',to_profile:p.profile_id}],idempotency_key:'g3-real-switch-'+run})
  for(const scope of ['plugins.develop','plugins.data','desktop.windows.read']){const grant=await must('desktop.permissions.grant',{subject:'agent',scope,idempotency_key:'g3-real-'+run+'-'+scope});createdGrants.push(grant.grant_id)}
  const session=await must('agent.sessions.create',{title:'G3 real generation '+run,idempotency_key:'g3-real-session-'+run});facts.session_id=session.session_id
  async function turn(text,label){
   const start=Date.now(),t=await must('agent.turns.submit',{session_id:session.session_id,client_message_id:'g3-real-'+run+'-'+label,text})
   const d=await eventually(async()=>{const observed=await must('agent.turns.get',{turn_id:t.turn_id});return ['succeeded','partial','failed','cancelled','unknown'].includes(observed.state)?observed:false})
   facts[label]={turn:d,seconds:(Date.now()-start)/1000,trace:await must('agent.turns.trace',{turn_id:t.turn_id})};verify(label+' real model turn succeeded',d.state==='succeeded');return t
  }
  const titles={tasks:'真實生成待辦 '+run,workspaces:'真實生成工作區 '+run}
  const t1=await turn(`新增一個獨立的受限生成待辦摘要面板，標題「${titles.tasks}」，寬320、紫色，最多4筆未完成待辦。既有元件保留。請用正式 development 能力建立新插件、隔離驗證、開啟測試資料預覽、安裝並啟用，完成後回讀。不要只提供計畫。`,'tasks-create')
  const t2=await turn(`再新增一個獨立的受限生成工作區按鈕面板，標題「${titles.workspaces}」，寬280，使用目前測試桌面前兩個工作區，按鈕叫「工作」和「整理」。保留既有元件。請建立新插件、隔離驗證、開啟測試資料預覽、安裝並啟用，再回讀。`,'workspaces-create')
  let artifacts=(await must('desktop.plugins.development.list')).artifacts
  const a=artifacts.find(a=>a.description.title===titles.tasks),b=artifacts.find(a=>a.description.title===titles.workspaces)
  verify('two real generated plugins validated and activated',a?.state==='active'&&b?.state==='active'&&a.origin.turn_id===t1.turn_id&&b.origin.turn_id===t2.turn_id&&[a,b].every(a=>a.validation.boundary.enforcement==='full'&&a.validation.stages.every(s=>s.result==='passed')))
  await turn('把剛才新增的待辦摘要面板寬度改380，最多顯示2筆。其他欄位保留。建立新版本並重新驗證後套用。','tasks-modify')
  await turn('把剛才新增的工作區面板寬度改340，第二個按鈕文字改「閱讀」。其他欄位保留。建立新版本並重新驗證後套用。','workspaces-modify')
  artifacts=(await must('desktop.plugins.development.list')).artifacts
  const aa=artifacts.find(x=>x.parent_id===a.artifact_id&&x.state==='active'),bb=artifacts.find(x=>x.parent_id===b.artifact_id&&x.state==='active')
  verify('both plugin kinds support real conversational version changes',aa?.description.width===380&&aa.description.content.max_items===2&&bb?.description.width===340&&bb.description.content.actions[1].label==='閱讀')
  facts.artifacts=await Promise.all([a,b,aa,bb].map(x=>must('desktop.plugins.development.get',{artifact_id:x.artifact_id})))
  facts.profile=await must('desktop.profiles.get');facts.jobs=await must('desktop.jobs.list')
  for(const artifact of [a,b])verify(artifact.description.title+' had a real preview',facts.artifacts.find(a=>a.artifact_id===artifact.artifact_id).previews.some(p=>p.opened))
  const events=await must('agent.sessions.read',{session_id:session.session_id,offset:0,limit:200});facts.models=events.events.filter(e=>e.type==='model/selection').map(e=>e.data)
 }
}catch(error){facts.error=String(error);process.exitCode=1;console.error(error)}
finally{
 try{for(const grant_id of createdGrants)await must('desktop.permissions.revoke',{grant_id});if(original){const p=(await must('desktop.profiles.get')).profile;await must('desktop.changes.propose',{base_revision:p.head_revision,ops:[{op:'switch_profile',to_profile:original.profile_id,to_revision:original.head_revision}],idempotency_key:'g3-real-restore-'+run})}if(preferences){const now=await must('agent.settings.describe');const {_meta,...s}=preferences;await must('agent.settings.patch',{expected_revision:now.revision,settings:{...s,revision:now.revision}})}await must('agent.runtime.stop')}catch(error){facts.restore_error=String(error);process.exitCode=1}
 writeFileSync(process.env.DITTO_G3_AGENT_OUT,JSON.stringify({ok:!process.exitCode,evidence_class:'development-headless-real-subscription',checks,facts},null,2))
}
