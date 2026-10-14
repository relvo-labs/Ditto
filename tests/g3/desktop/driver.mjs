import {execFileSync as sourceExec} from 'node:child_process'
// Real Wayfire + Shell + hostd. All mutations use authenticated Core calls;
// generated diagnostics are read-only observations of the mounted QML.
import {createConnection} from 'node:net'
import {readFileSync,writeFileSync} from 'node:fs'
import {spawnSync,execFileSync} from 'node:child_process'
const checks=[],facts={source:JSON.parse(sourceExec("python3",["tests/g3/source.py"]))},sleep=ms=>new Promise(r=>setTimeout(r,ms))
const line=(path,text)=>new Promise((resolve,reject)=>{
 const socket=createConnection(path),timer=setTimeout(()=>{socket.destroy();reject(new Error('relay timeout'))},90000);let buffer=''
 socket.on('connect',()=>socket.write(text+'\n'));socket.on('error',reject);socket.on('data',data=>{buffer+=data;if(buffer.includes('\n')){clearTimeout(timer);socket.destroy();resolve(JSON.parse(buffer.split('\n')[0]))}})
})
const call=(method,params={})=>{
 if(process.env.DITTO_G3_RUN_SUFFIX&&params.idempotency_key)params={...params,idempotency_key:process.env.DITTO_G3_RUN_SUFFIX+'-'+params.idempotency_key}
 return line(process.env.DITTO_G1_RELAY,JSON.stringify({method,params}))
}
const must=async(method,params)=>{const r=await call(method,params);if(r.error)throw new Error(method+': '+JSON.stringify(r.error));return r.result}
const shell=command=>line(process.env.DITTO_RUNTIME_DIR+'/shell.sock',command)
const eventually=async(fn)=>{for(let i=0;i<800;i++){const v=await fn();if(v)return v;await sleep(50)}throw new Error('condition timed out')}
const verify=(name,yes)=>{if(!yes)throw new Error(name);checks.push(name);console.log('PASS '+name)}
const head=async()=>(await must('desktop.profiles.get')).profile.head_revision
const waitJob=job=>eventually(async()=>{const j=await must('desktop.jobs.get',{job_id:job.job_id});return ['succeeded','failed','cancelled'].includes(j.state)?j:false})
async function prepare(description,parent_id){
 const a=await must('desktop.plugins.development.create',{description,parent_id,request_summary:'G3 real desktop test',idempotency_key:'create-'+description.plugin_id+'-'+description.version})
 const j=await waitJob(await must('desktop.plugins.development.validate',{artifact_id:a.artifact_id,idempotency_key:'validate-'+a.artifact_id}))
 facts[a.artifact_id+'-validation']=j
 verify(description.plugin_id+' '+description.version+' five isolated stages',j.state==='succeeded'&&j.result.boundary.enforcement==='full'&&j.result.stages.every(s=>s.result==='passed'))
 return must('desktop.plugins.development.publish',{artifact_id:a.artifact_id})
}
async function activate(a,key){const change=await must('desktop.plugins.development.activate',{artifact_id:a.artifact_id,base_revision:await head(),idempotency_key:key});facts[key]=change;verify(key+' committed',change.state==='committed');return change}
try{
 const initial=await head()
 facts.application_pid=Number(process.env.DITTO_G3_APP_PID)
 await must("desktop.tasks.add",{text:"G3 service-backed task",source:"own"})
 const workspaces=await must('desktop.workspaces.list');facts.workspaces=workspaces
 const tasks=JSON.parse(readFileSync('crates/ditto-generation/examples/tasks-summary.json','utf8'));tasks.data={schema_version:1,fields:{note:'text'}}
 if(process.env.DITTO_G3_RUN_SUFFIX)tasks.plugin_id+='.'+process.env.DITTO_G3_RUN_SUFFIX
 const a=await prepare(tasks)
 await activate(a,'tasks-activate')
 const mounted=await eventually(async()=>{const l=await must('desktop.plugins.list');return l.entries.find(e=>e.package===tasks.plugin_id&&e.state.kind==='active')})
 verify('Core reads back mounted generated tasks panel',!!mounted)
 const view=await eventually(async()=>{const list=await shell('generated');return list.find(e=>e.artifact_id===a.artifact_id&&e.shown&&e.ready)})
 facts.tasksView=view;verify('mounted panel reads actual tasks service',view.data_available&&view.tasks.length>0)
 const current=await must('desktop.plugins.development.data_get',{artifact_id:a.artifact_id})
 await must('desktop.plugins.development.data_write',{artifact_id:a.artifact_id,expected_revision:current.revision,payload:{note:'retain this note'}})
 const preview=await must('desktop.plugins.development.preview',{artifact_id:a.artifact_id,idempotency_key:'real-preview'})
 const opened=await eventually(async()=>{const j=await must('desktop.jobs.get',{job_id:preview.job_id});if(['failed','cancelled'].includes(j.state))throw new Error('preview failed: '+JSON.stringify(j));return j.phase==='preview_opened'?j:false})
 facts.previewOpened=opened;verify('real confined Wayland preview opens',!!opened)
 if(process.env.DITTO_G3_PHYSICAL_CONTEXT)execFileSync('python3',['tests/g3/reference/observe.py','preview'],{stdio:'inherit'})
 const second=await must('desktop.plugins.development.preview',{artifact_id:a.artifact_id,idempotency_key:'second-preview'});
 await eventually(async()=>{const j=await must('desktop.jobs.get',{job_id:second.job_id});return j.phase==='preview_opened'});
 const thirdDescription=structuredClone(tasks);thirdDescription.version='0.1.1';thirdDescription.title='Queued candidate';
 const queuedArtifact=await must('desktop.plugins.development.create',{description:thirdDescription,parent_id:a.artifact_id,request_summary:'Queued validation test',idempotency_key:'queued-create'});
 const queued=await must('desktop.plugins.development.validate',{artifact_id:queuedArtifact.artifact_id,idempotency_key:'queued-validate'});
 await sleep(250);
 verify('third generation job stays queued',(await must('desktop.jobs.get',{job_id:queued.job_id})).state==='queued');
 verify('global pool admits only two jobs',(await must('desktop.jobs.list')).jobs.filter(j=>j.state==='running').length===2);
 await must('desktop.jobs.cancel',{job_id:queued.job_id});
 verify('queued cancellation reconciles artifact',(await must('desktop.plugins.development.get',{artifact_id:queuedArtifact.artifact_id})).state==='failed');
 if(process.env.DITTO_G3_PHYSICAL_CONTEXT)execFileSync('python3',['tests/g3/reference/observe.py','cancel-previews',preview.job_id,second.job_id],{stdio:'inherit'})
 for(const job of [preview,second]){if((await must('desktop.jobs.get',{job_id:job.job_id})).state!=='cancelled')await must('desktop.jobs.cancel',{job_id:job.job_id});verify('preview '+job.job_id+' cancellation finishes',(await waitJob(job)).state==='cancelled');}

 verify('cancelled preview retains opening evidence',(await must('desktop.plugins.development.get',{artifact_id:a.artifact_id})).previews.filter(p=>p.opened&&p.state==='cancelled').length===2);
 const modified=structuredClone(tasks);modified.version='0.2.0';modified.title='修改後的待辦摘要';modified.width=360;modified.content.max_items=2;modified.data={schema_version:2,fields:{title:'text'},migration:{from_version:1,rename:{note:'title'},defaults:{},remove:[],rollback:'snapshot'}}
 const b=await prepare(modified,a.artifact_id);const upgraded=await activate(b,'tasks-upgrade')
 verify('data migrated with profile revision',(await must('desktop.plugins.development.data_get',{artifact_id:b.artifact_id})).payload.title==='retain this note')
 const next=await eventually(async()=>{const rows=await shell('generated');return rows.find(e=>e.artifact_id===b.artifact_id&&e.title===modified.title)})
 verify('modified panel is rendered',next.width===360&&next.tasks.length<=2)
 const undo=await must('desktop.changes.undo',{change_id:upgraded.change_id});facts.undo=undo;verify('undo committed',undo.state==='committed')
 verify('old data snapshot restored',(await must('desktop.plugins.development.data_get',{artifact_id:a.artifact_id})).payload.note==='retain this note')
 verify('old panel restored',!!(await eventually(async()=>{const rows=await shell('generated');return rows.find(e=>e.artifact_id===a.artifact_id)})))
 // Two consecutive modifications, compatible data rollback, then return
 // directly to the immutable first artifact and its original snapshot.
 await activate(b,'tasks-upgrade-again')
 const twice=structuredClone(modified);twice.version='0.3.0';twice.title='第二次修改的待辦摘要';twice.width=400;twice.data={schema_version:3,fields:{label:'text'},migration:{from_version:2,rename:{title:'label'},defaults:{},remove:[],rollback:'snapshot'}}
 const c=await prepare(twice,b.artifact_id);await activate(c,'tasks-second-upgrade')
 verify('second data migration is read from the actual owner',(await must('desktop.plugins.development.data_get',{artifact_id:c.artifact_id})).payload.label==='retain this note')
 verify('second modified version is actually mounted',!!(await eventually(async()=>(await shell('generated')).find(e=>e.artifact_id===c.artifact_id&&e.width===400&&e.shown))))
 const compatible=structuredClone(twice);compatible.version='0.4.0';compatible.data={schema_version:4,fields:{label:'text'},migration:{from_version:3,rename:{},defaults:{},remove:[],rollback:'compatible'}}
 const d=await prepare(compatible,c.artifact_id);await activate(d,'tasks-compatible-upgrade')
 const latest=await must('desktop.plugins.development.data_get',{artifact_id:d.artifact_id})
 await must('desktop.plugins.development.data_write',{artifact_id:d.artifact_id,expected_revision:latest.revision,payload:{label:'compatible edits survive'}})
 await activate(c,'tasks-compatible-rollback')
 verify('compatible rollback preserves newer readable values',(await must('desktop.plugins.development.data_get',{artifact_id:c.artifact_id})).payload.label==='compatible edits survive')
 await activate(a,'tasks-return-to-first')
 verify('two modifications can return to the first data snapshot',(await must('desktop.plugins.development.data_get',{artifact_id:a.artifact_id})).payload.note==='retain this note')
 verify('first version appearance returns after two modifications',!!(await eventually(async()=>(await shell('generated')).find(e=>e.artifact_id===a.artifact_id&&e.width===tasks.width&&e.title===tasks.title))))
 const actions=JSON.parse(readFileSync('crates/ditto-generation/examples/workspace-actions.json','utf8'));actions.content.actions=workspaces.workspaces.slice(0,2).map((w,i)=>({workspace_id:w.id,label:'G3 工作區 '+i}))
 if(process.env.DITTO_G3_RUN_SUFFIX)actions.plugin_id+='.'+process.env.DITTO_G3_RUN_SUFFIX
 const w=await prepare(actions);await activate(w,'workspaces-activate')
 verify('both generated panels coexist',(await shell('generated')).filter(e=>e.shown&&e.ready).length===2)
 await sleep(300);
 const workspaceView=await eventually(async()=>{const rows=await shell('generated');return rows.find(e=>e.artifact_id===w.artifact_id&&e.buttons.length===2)});
 const button=workspaceView.buttons[1];verify('workspace action is enabled',button.enabled);
 for(const [method,args] of [['stipc/move_cursor',{x:Math.round(button.x),y:Math.round(button.y)}],['stipc/feed_button',{combo:'BTN_LEFT',mode:'full'}]])execFileSync('python3',['tools/compositor-probe/functional/wayfire-ipc.py',method,JSON.stringify(args)]);
 await sleep(100);facts.workspaceButton=button;facts.workspaceClickView=await shell('generated');
 verify('actual button click activates the requested workspace',!!(await eventually(async()=>(await must('desktop.workspaces.list')).workspaces.find(ws=>ws.id===button.workspace_id&&ws.active))));

 // An irreversible schema never gives the old artifact newer data. Removing
 // that plugin is distinct from deleting its retained data.
 await activate(b,'irreversible-base-b');await activate(c,'irreversible-base-c');await activate(d,'irreversible-base-d')
 const irreversible=structuredClone(compatible);irreversible.version='0.5.0';irreversible.data={schema_version:5,fields:{final:'text'},migration:{from_version:4,rename:{label:'final'},defaults:{},remove:[],rollback:'unavailable'}}
 const e=await prepare(irreversible,d.artifact_id);await activate(e,'tasks-irreversible-upgrade')
 const heldHead=await head(),retained=await must('desktop.plugins.development.data_get',{artifact_id:e.artifact_id})
 const refused=await call('desktop.plugins.development.activate',{artifact_id:a.artifact_id,base_revision:heldHead,idempotency_key:'irreversible-rollback-denied'})
 verify('irreversible rollback is refused without moving the revision',refused.error?.name==='preflight_rejected'&&await head()===heldHead)
 verify('old version cannot read incompatible data',(await call('desktop.plugins.development.data_get',{artifact_id:a.artifact_id})).error?.name==='conflict')
 const owner=(await must('desktop.profiles.get')).document.entries.find(entry=>entry.package===e.description.plugin_id)
 const removed=await must('desktop.changes.propose',{base_revision:await head(),ops:[{op:'remove_entry',entry_id:owner.entry_id}],idempotency_key:'remove-with-data-retained'})
 verify('generated plugin can be removed without deleting its data',removed.state==='committed'&&JSON.stringify((await must('desktop.plugins.development.data_get',{artifact_id:e.artifact_id})).payload)===JSON.stringify(retained.payload))

 const history=await must('desktop.plugins.development.get',{artifact_id:b.artifact_id});verify('activation journal includes commit and preserved immutable source',history.activations.some(x=>x.state==='committed')&&history.parent_id===a.artifact_id)
 process.kill(facts.application_pid,0);verify('native application survives generation and rollback',(await must('desktop.windows.list')).windows.some(window=>window.app_id==='ditto-g3-survival'));
 facts.initial=initial;facts.final=await head()
 if(process.env.DITTO_G3_PHYSICAL_CONTEXT)facts.physical_context=JSON.parse(readFileSync(process.env.DITTO_G3_PHYSICAL_CONTEXT,'utf8'))
 writeFileSync(process.env.DITTO_G3_DESKTOP_OUT,JSON.stringify({ok:true,evidence_class:process.env.DITTO_G3_PHYSICAL_CONTEXT?'reference-physical-seat':'development-headless-wayfire',checks,facts},null,2))
}catch(error){writeFileSync(process.env.DITTO_G3_DESKTOP_OUT,JSON.stringify({ok:false,checks,facts,error:String(error)},null,2));console.error(error);process.exitCode=1}
