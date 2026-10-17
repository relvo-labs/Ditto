// Real model oracle. Fixture Profile, natural requests, real Core readback.
import {createConnection} from 'node:net'
import {readFileSync,writeFileSync} from 'node:fs'
import {execFileSync} from 'node:child_process'
import {descriptionChecks} from './description-checks.mjs'
const checks=[],facts={source:JSON.parse(execFileSync('python3',['tests/g3/source.py']))},sleep=ms=>new Promise(r=>setTimeout(r,ms)),run=Date.now().toString()
const line=(path,request)=>new Promise((resolve,reject)=>{const socket=createConnection(path),timer=setTimeout(()=>{socket.destroy();reject(new Error('relay timeout'))},60000);let buffer='';socket.on('connect',()=>socket.write(request+'\n'));socket.on('error',error=>{clearTimeout(timer);reject(error)});socket.on('data',data=>{buffer+=data;if(buffer.includes('\n')){clearTimeout(timer);socket.destroy();resolve(JSON.parse(buffer.split('\n')[0]))}})})
const call=(method,params={})=>line(process.env.DITTO_G1_RELAY,JSON.stringify({method,params}))
const rendered=()=>line(process.env.DITTO_RUNTIME_DIR+'/shell.sock','generated')
const must=async(method,params)=>{const r=await call(method,params);if(r.error)throw new Error(method+': '+JSON.stringify(r.error));return r.result}
const verify=(name,yes)=>{if(!yes)throw new Error(name);checks.push(name);console.log('PASS '+name)}
const eventually=async(fn,tries=600)=>{for(let i=0;i<tries;i++){const v=await fn();if(v)return v;await sleep(500)}throw new Error('condition timed out')}
let original,preferences
const createdGrants=[]
try{
 await eventually(async()=>{const r=await call('desktop.profiles.get');return r.result})
 facts.original_profile=await must('desktop.profiles.get');original=facts.original_profile.profile;preferences=await must('agent.settings.describe')
 const {_meta,...s}=preferences
 await must('agent.settings.patch',{expected_revision:s.revision,settings:{...s,enabled:true,max_tool_calls:24,turn_timeout_ms:120000}})
 const effective=await must('agent.settings.describe');facts.model_settings={provider:effective.provider,model:effective.model,reasoning_effort:effective.reasoning_effort,revision:effective.revision,max_tool_calls:effective.max_tool_calls,turn_timeout_ms:effective.turn_timeout_ms}
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
  for(const [name,passed] of Object.entries(descriptionChecks(facts.artifacts)))verify(name,passed)
  facts.profile=await must('desktop.profiles.get');facts.jobs=await must('desktop.jobs.list')
  facts.rendered=await eventually(async()=>{const rows=await rendered();return [aa,bb].every(a=>rows.some(r=>r.artifact_id===a.artifact_id&&r.shown&&r.ready&&r.width===a.description.width))?rows:false},120)
  const tasksView=facts.rendered.find(r=>r.artifact_id===aa.artifact_id),workspaceView=facts.rendered.find(r=>r.artifact_id===bb.artifact_id)
  verify('real generated tasks panel reads the live service',tasksView.data_available&&tasksView.tasks.length<=2)
  verify('real generated workspace buttons are usable',workspaceView.buttons.length===bb.description.content.actions.length&&workspaceView.buttons.every(b=>b.enabled))
  const button=workspaceView.buttons[1]
  for(const [method,args] of [['stipc/move_cursor',{x:Math.round(button.x),y:Math.round(button.y)}],['stipc/feed_button',{combo:'BTN_LEFT',mode:'full'}]])execFileSync('python3',['tools/compositor-probe/functional/wayfire-ipc.py',method,JSON.stringify(args)])
  facts.workspace_action=await eventually(async()=>{const rows=await rendered(),workspaces=await must('desktop.workspaces.list');return rows.some(r=>r.artifact_id===bb.artifact_id&&r.last_requested_workspace===button.workspace_id)&&workspaces.workspaces.some(w=>w.id===button.workspace_id&&w.active)?{button,workspaces}:false},120)
  verify('real generated button activates its requested workspace',!!facts.workspace_action)
  for(const artifact of [a,b])verify(artifact.description.title+' had a real preview',facts.artifacts.find(a=>a.artifact_id===artifact.artifact_id).previews.some(p=>p.opened))
  const events=await must('agent.sessions.read',{session_id:session.session_id,offset:0,limit:200});facts.models=events.events.filter(e=>e.type==='model/selection').map(e=>e.data)
 }
}catch(error){facts.error=String(error);process.exitCode=1;console.error(error)}
finally{
 // Attempt every restoration even when an earlier step fails. A successful
 // API response alone is insufficient: read back composition, settings and
 // revocations before reporting the test as complete.
 facts.restore_errors=[]
 const restore=async(name,fn)=>{try{await fn()}catch(error){facts.restore_errors.push({step:name,error:String(error)});process.exitCode=1}}
 for(const grant_id of createdGrants)await restore('revoke '+grant_id,()=>must('desktop.permissions.revoke',{grant_id}))
 if(original)await restore('profile',async()=>{const p=(await must('desktop.profiles.get')).profile;if(p.profile_id!==original.profile_id||p.head_revision!==original.head_revision)await must('desktop.changes.propose',{base_revision:p.head_revision,ops:[{op:'switch_profile',to_profile:original.profile_id,to_revision:original.head_revision}],idempotency_key:'g3-real-restore-'+run});facts.restored_profile=await must('desktop.profiles.get');verify('original composition restored by readback',facts.restored_profile.profile.profile_id===original.profile_id&&facts.restored_profile.revision.document_sha256===facts.original_profile.revision.document_sha256)})
 if(preferences)await restore('settings',async()=>{const now=await must('agent.settings.describe');const {_meta,...s}=preferences;await must('agent.settings.patch',{expected_revision:now.revision,settings:{...s,revision:now.revision}});const normalize=({_meta,revision,...settings})=>settings;verify('original settings restored by readback',JSON.stringify(normalize(await must('agent.settings.describe')))===JSON.stringify(normalize(preferences)))})
 await restore('grants readback',async()=>{const permissions=await must('desktop.permissions.list',{subject:'agent',include_revoked:true});verify('all test grants revoked by readback',createdGrants.every(id=>permissions.grants.some(g=>g.grant_id===id&&g.revoked_at)))})
 await restore('stop Agent',()=>must('agent.runtime.stop'))
 if(process.env.DITTO_G3_PHYSICAL_CONTEXT)facts.physical_context=JSON.parse(readFileSync(process.env.DITTO_G3_PHYSICAL_CONTEXT,'utf8'))
 writeFileSync(process.env.DITTO_G3_AGENT_OUT,JSON.stringify({ok:!process.exitCode,evidence_class:process.env.DITTO_G3_PHYSICAL_CONTEXT?'reference-physical-real-subscription':'development-headless-real-subscription',checks,facts},null,2))
}
