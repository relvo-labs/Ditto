// Loopback scripted model. No subscription, keyring, or external model calls.
import {readFileSync,appendFileSync} from 'node:fs'
import {startProvider,toolOutputs,userText,call,say} from '../../g2/codex/mock-provider.mjs'
const provider=await startProvider(async body=>{
 appendFileSync(process.argv[2],JSON.stringify(body)+'\n')
 const output=toolOutputs(body),text=userText(body),modify=text.includes('modify'),workspace=text.includes('g3-workspaces')
 const result=id=>JSON.parse(output.get(id))
 if(!output.has('profile'))return [call('desktop__profiles__get',{},'profile')]
 if(workspace&&!output.has('workspaces'))return [call('desktop__workspaces__list',{},'workspaces')]
 if(modify&&!output.has('artifacts'))return [call('desktop__plugins__development__list',{},'artifacts')]
 let description=JSON.parse(readFileSync('crates/ditto-generation/examples/'+(workspace?'workspace-actions':'tasks-summary')+'.json','utf8'))
 description.plugin_id='local.generated.scripted_'+(workspace?'workspaces':'tasks');description.version=modify?'1.1.0':'1.0.0';description.title=workspace?'G3 腳本模型工作區':'G3 腳本模型待辦'
 if(workspace)description.content.actions=result('workspaces').workspaces.slice(0,2).map((w,i)=>({workspace_id:w.id,label:'Workspace '+i}))
 let parent_id
 if(modify){const parent=result('artifacts').artifacts.find(a=>a.description.plugin_id===description.plugin_id);parent_id=parent.artifact_id;description=structuredClone(parent.description);description.version='1.1.0';description.width=workspace?340:380;if(workspace)description.content.actions[1].label='Revised workspace';else description.content.max_items=2}
 if(!output.has('create'))return [call('desktop__plugins__development__create',{description,parent_id,request_summary:text,idempotency_key:description.plugin_id+'-'+description.version},'create')]
 if(result('create').error)return [say('沒有取得生成權限，未建立插件。')]
 const id=result('create').artifact_id
 if(!output.has('validate'))return [call('desktop__plugins__development__validate',{artifact_id:id,idempotency_key:'validate-'+id},'validate')]
 const polls=[...output.keys()].filter(k=>k.startsWith('job-'))
 if(!polls.length||!['succeeded','failed','cancelled'].includes(result(polls.at(-1)).state)){
  await new Promise(r=>setTimeout(r,300));return [call('desktop__jobs__get',{job_id:result('validate').job_id},'job-'+polls.length)]
 }
 if(result(polls.at(-1)).state!=='succeeded')return [say('隔離驗證未完成，沒有安裝。')]
 if(!modify) {
  if(!output.has('preview'))return [call('desktop__plugins__development__preview',{artifact_id:id,idempotency_key:'preview-'+id},'preview')];
  const previews=[...output.keys()].filter(k=>k.startsWith('preview-state-'));
  if(!previews.length || result(previews.at(-1)).phase!=='preview_opened') {
   if(previews.length&&['failed','cancelled','succeeded'].includes(result(previews.at(-1)).state))return [say('預覽未開啟。')];
   await new Promise(r=>setTimeout(r,300));return [call('desktop__jobs__get',{job_id:result('preview').job_id},'preview-state-'+previews.length)];
  }
  if(!output.has('preview-cancel'))return [call('desktop__jobs__cancel',{job_id:result('preview').job_id},'preview-cancel')];
 }
 if(!output.has('publish'))return [call('desktop__plugins__development__publish',{artifact_id:id},'publish')]
 if(!output.has('activate'))return [call('desktop__plugins__development__activate',{artifact_id:id,base_revision:result('profile').profile.head_revision,idempotency_key:'activate-'+id},'activate')]
 if(!output.has('readback'))return [call('desktop__plugins__development__get',{artifact_id:id},'readback')]
 return [say(result('readback').state==='active'?'已完成並回讀生成插件。':'啟用未完成。')]
})
console.log(provider.port)
