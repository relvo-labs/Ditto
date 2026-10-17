// Kill ONLY Core with two real native previews alive, then restart its store.
// The compositor and candidate scopes are separate processes throughout.
import {spawn,execFileSync} from 'node:child_process'
import {createConnection} from 'node:net'
import {mkdtempSync,openSync,closeSync,existsSync,readFileSync,writeFileSync,readdirSync} from 'node:fs'
import {resolve} from 'node:path'
const workspace=resolve(import.meta.dirname,'../../..'),root=mkdtempSync(workspace+'/artifacts/g3/restart-'),checks=[],facts={source:JSON.parse(execFileSync('python3',[workspace+'/tests/g3/source.py']))},sleep=ms=>new Promise(r=>setTimeout(r,ms))
const manager={...process.env,DBUS_SESSION_BUS_ADDRESS:`unix:path=/run/user/${process.getuid()}/bus`}
let core,relayPath;const scopes=new Set(),relays=new Set()
const verify=(name,yes)=>{if(!yes)throw new Error(name);checks.push(name);console.log('PASS '+name)}
const eventually=async(fn)=>{for(let i=0;i<500;i++){const v=await fn();if(v)return v;await sleep(20)}throw new Error('condition timed out')}
const call=(method,params={})=>new Promise((resolve,reject)=>{const socket=createConnection(relayPath),timer=setTimeout(()=>{socket.destroy();reject(new Error('relay timeout'))},60000);let buffer='';socket.on('connect',()=>socket.write(JSON.stringify({method,params})+'\n'));socket.on('error',reject);socket.on('data',data=>{buffer+=data;if(buffer.includes('\n')){clearTimeout(timer);socket.destroy();resolve(JSON.parse(buffer.split('\n')[0]))}})})
const must=async(method,params)=>{const r=await call(method,params);if(r.error)throw new Error(method+': '+JSON.stringify(r.error));return r.result}
function captureRelay(){for(const pid of readdirSync('/proc').filter(s=>/^\d+$/.test(s))){try{if(readFileSync('/proc/'+pid+'/cmdline','utf8').split('\0').includes(relayPath))relays.add(Number(pid))}catch{}}}
async function start(generation){
 relayPath=root+'/relay-'+generation+'.sock';const log=openSync(root+'/core-'+generation+'.log','w')
 core=spawn(workspace+'/target/debug/ditto-core',['serve','--compositor','fixture','--launch',`dittoctl 0.3.0 ${process.execPath} ${workspace}/tests/g1/lib/relay.mjs ${relayPath}`],{env:{...process.env,DITTO_RUNTIME_DIR:root+'/run',DITTO_DATA_DIR:root+'/store',DITTO_SYSTEM:'none'},stdio:['ignore',log,log],detached:true});closeSync(log)
 await eventually(()=>existsSync(relayPath));captureRelay()
 await eventually(async()=>{const l=await must('desktop.capabilities.list');return l.capabilities.find(c=>c.capability_id==='desktop.plugins.development.validate')?.availability.available})
 await sleep(100)
}
const get=id=>must('desktop.jobs.get',{job_id:id})
const preview=async(a,key)=>{const j=await must('desktop.plugins.development.preview',{artifact_id:a.artifact_id,idempotency_key:key});scopes.add('ditto-job-'+j.job_id.toLowerCase()+'.scope');await eventually(async()=>(await get(j.job_id)).phase==='preview_opened');return j}
try{
 await start(1);const head=(await must('desktop.profiles.get')).profile.head_revision
 const description=JSON.parse(readFileSync(workspace+'/crates/ditto-generation/examples/tasks-summary.json','utf8'))
 const a=await must('desktop.plugins.development.create',{description,request_summary:'restart fixture',idempotency_key:'create'})
 const validation=await must('desktop.plugins.development.validate',{artifact_id:a.artifact_id,idempotency_key:'validate'})
 await eventually(async()=>{const j=await get(validation.job_id);if(j.state==='failed')throw new Error('validation failed');return j.state==='succeeded'})
 const first=await preview(a,'first'),second=await preview(a,'second');facts.jobs=[first.job_id,second.job_id]
 const groups=[...scopes].map(scope=>execFileSync('systemctl',['--user','show',scope,'-p','ControlGroup','--value'],{env:manager}).toString().trim());facts.old_groups=groups
 const nativeGroups=new Set();
 for(const pid of readdirSync('/proc').filter(s=>/^\d+$/.test(s)))try{const cmd=readFileSync('/proc/'+pid+'/cmdline','utf8');if(cmd.includes(root)&&cmd.includes('ditto-generation-runner'))nativeGroups.add(readFileSync('/proc/'+pid+'/cgroup','utf8').trim().split('::')[1])}catch{}
 facts.native_groups=[...nativeGroups];verify('both previews have separate native cgroups',nativeGroups.size===2)
 process.kill(core.pid,'SIGKILL');await new Promise(r=>core.once('exit',r));for(const pid of relays){try{process.kill(pid,'SIGTERM')}catch{}}
 await start(2)
 for(const id of facts.jobs){const job=await get(id);verify('interrupted preview '+id+' is not replayed',job.state==='failed'&&job.error_key==='job.interrupted')}
 verify('old worker and candidate cgroups are empty before replacement admission',[...groups,...nativeGroups].every(group=>{const path='/sys/fs/cgroup'+group+'/cgroup.events';return !existsSync(path)||readFileSync(path,'utf8').includes('populated 0')}))
 const readback=await must('desktop.plugins.development.get',{artifact_id:a.artifact_id})
 verify('preview opening history survives restart',readback.previews.length===2&&readback.previews.every(p=>p.opened&&p.state==='failed'))
 const replacement=await preview(a,'replacement');verify('a new preview can use the recovered pool',!!replacement.job_id)
 await must('desktop.jobs.cancel',{job_id:replacement.job_id});await eventually(async()=>(await get(replacement.job_id)).state==='cancelled')
 verify('profile revision survives the Core crash',(await must('desktop.profiles.get')).profile.head_revision===head)
 process.kill(Number(process.env.DITTO_G3_COMPOSITOR_PID),0);verify('compositor survives candidate and Core restart',true)
 writeFileSync(root+'/result.json',JSON.stringify({ok:true,checks,facts,evidence_class:'development-headless-wayfire'},null,2));console.log('Evidence: '+root+'/result.json')
}catch(error){writeFileSync(root+'/result.json',JSON.stringify({ok:false,checks,facts,error:String(error)},null,2));console.error(error);process.exitCode=1}
finally{
 if(core&&core.exitCode===null)try{process.kill(core.pid,'SIGTERM')}catch{}
 await sleep(300);if(core&&core.exitCode===null)try{process.kill(core.pid,'SIGKILL')}catch{}
 for(const pid of relays)try{process.kill(pid,'SIGTERM')}catch{}
 for(const scope of scopes)try{execFileSync('systemctl',['--user','stop',scope],{env:manager,stdio:'ignore',timeout:3000})}catch{}
}
