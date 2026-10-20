import {readFileSync,writeFileSync,existsSync,readdirSync,chmodSync,appendFileSync,statSync} from 'node:fs'
import {execFileSync} from 'node:child_process'
import {connect,sleep} from '../../g1/lib/core-client.mjs'

const checks=[],facts={}
const verify=(name,value)=>{if(!value)throw new Error('check failed: '+name);checks.push(name)}
const eventually=async(fn,tries=300,ms=100)=>{for(let i=0;i<tries;i++){const v=await fn();if(v)return v;await sleep(ms)}return false}
const report=r=>writeFileSync(process.env.DITTO_G2_TEST_OUT,JSON.stringify(r))
const unitOf=job=>'ditto-job-'+job.job_id.toLowerCase().replace(/[^a-z0-9-]/g,'-')
// Every job scope this run creates, for run.mjs to stop. Never a ditto-job-*
// glob: that would also stop a logged-in session's jobs (#124).
const own=job=>{if(job?.job_id)appendFileSync(process.env.DITTO_G2_ROOT+'/job-scopes',unitOf(job)+'.scope\n');return job}
const show=(unit,prop)=>{try{return execFileSync('systemctl',['--user','show','-p',prop,'--value',unit+'.scope'],{encoding:'utf8'}).trim()}catch{return ''}}
try{
  const core=await connect()
  await eventually(async()=>(await core.call('desktop.jobs.list',{})).error?.data?.reason!=='recovering')
  const catalog=await core.must('desktop.capabilities.list')
  const submit=catalog.capabilities.find(c=>c.capability_id==='desktop.jobs.submit')
  verify('the pool is available (systemd user manager present)',submit.availability.available!==false)
  const get=id=>core.must('desktop.jobs.get',{job_id:id})
  const until=async(id,states,tries=600)=>eventually(async()=>{const j=await get(id);return states.includes(j.state)?j:false},tries)
  const job=(kind,params,key)=>core.must('desktop.jobs.submit',{kind,params,idempotency_key:key}).then(own)

  // ① admission: three jobs, two run, one waits
  const a=await job('test.sleep',{ms:4000},'a'),b=await job('test.sleep',{ms:4000},'b'),c=await job('test.sleep',{ms:4000},'c')
  verify('submission is idempotent',(await job('test.sleep',{ms:4000},'a')).job_id===a.job_id)
  await eventually(async()=>(await get(a.job_id)).state==='running'&&(await get(b.job_id)).state==='running')
  const states=[(await get(a.job_id)).state,(await get(b.job_id)).state,(await get(c.job_id)).state]
  verify('at most two run, the third waits: '+states,states.filter(s=>s==='running').length===2&&states[2]==='queued')
  facts.memory_max=show(unitOf(a),'MemoryMax');facts.cpu_quota=show(unitOf(a),'CPUQuotaPerSecUSec');facts.tasks_max=show(unitOf(a),'TasksMax')
  verify('each worker runs in its own scope with the D-06b quota: '+JSON.stringify(facts),facts.memory_max==='268435456'&&facts.cpu_quota==='500ms'&&facts.tasks_max==='32')
  // ② cancel the queued one: it never starts
  const cq=await core.must('desktop.jobs.cancel',{job_id:c.job_id})
  verify('a queued job cancelled never starts',cq.state==='cancelled'&&show(unitOf(c),'LoadState')!=='loaded')
  // ③ cancel a running one: cancelling, then cancelled, worker gone
  const cr=await core.must('desktop.jobs.cancel',{job_id:a.job_id})
  verify('a running job goes to cancelling',['cancelling','cancelled'].includes(cr.state))
  const cancelled=await until(a.job_id,['cancelled','succeeded','failed'],80)
  verify('then cancelled, its scope gone',cancelled.state==='cancelled'&&show(unitOf(a),'ActiveState')!=='active')
  const okB=await until(b.job_id,['succeeded','failed','cancelled'])
  verify('the other completes with its result',okB.state==='succeeded'&&okB.result?.slept_ms===4000)
  // ④ deadline
  const d=await job('test.spin',{ms:20000,deadline_ms:1500},'deadline')
  const dl=await until(d.job_id,['succeeded','failed','cancelled'])
  verify('past its deadline a job fails as such',dl.state==='failed'&&dl.error_key==='job.deadline')
  // ⑤ CPU quota is enforced: a spinning worker gets about half a core
  const spin=await job('test.spin',{ms:4000},'spin')
  await until(spin.job_id,['running'])
  const usage=()=>Number(show(unitOf(spin),'CPUUsageNSec'))
  await sleep(700);const u0=usage(),t0=Date.now();await sleep(2000);const u1=usage(),t1=Date.now()
  facts.spin_cpu_share=Math.round((u1-u0)/1e6/(t1-t0)*100)/100
  verify('CPU quota holds a busy worker near 50% of one core: '+facts.spin_cpu_share,facts.spin_cpu_share>0.2&&facts.spin_cpu_share<=0.6)
  await until(spin.job_id,['succeeded','failed'])
  // ⑥ memory limit is enforced: 512 MiB under MemoryMax=256M is killed
  const hog=await job('test.memory',{mb:512},'hog')
  const oom=await until(hog.job_id,['succeeded','failed','cancelled'])
  verify('a worker over its memory limit is killed and reported: '+oom.error_key,oom.state==='failed'&&oom.error_key==='job.out_of_memory')
  const fits=await job('test.memory',{mb:64},'fits')
  verify('a worker within its limit completes',(await until(fits.job_id,['succeeded','failed'])).state==='succeeded')
  // ⑦ the real kind: verify installed packages, then catch a tampered one
  const v=await job('packages.verify',{},'verify-1')
  const verified=await until(v.job_id,['succeeded','failed'])
  facts.verified=verified.result
  verify('packages.verify checks every installed package',verified.state==='succeeded'&&verified.result.checked>0&&verified.result.mismatched.length===0)
  const pkgRoot=process.env.DITTO_G2_ROOT+'/store/data/packages/sha256'
  const dirs=existsSync(pkgRoot)?readdirSync(pkgRoot).filter(n=>statSync(pkgRoot+'/'+n).isDirectory()&&!n.startsWith('.')):[]
  const victim=dirs.map(d=>pkgRoot+'/'+d+'/manifest.json').find(existsSync)
  verify('found an installed package to tamper with',!!victim)
  chmodSync(victim.replace('/manifest.json',''),0o700);chmodSync(victim,0o600);appendFileSync(victim,' ')
  const v2=await job('packages.verify',{},'verify-2')
  const tampered=await until(v2.job_id,['succeeded','failed'])
  verify('a changed package is reported as mismatched',tampered.result?.mismatched?.length===1)
  // ⑧ the queue is bounded
  const fill=[];for(let i=0;i<40;i++){const r=await core.call('desktop.jobs.submit',{kind:'test.sleep',params:{ms:5000},idempotency_key:'fill-'+i});own(r.result);fill.push(r)}
  facts.refused=fill.filter(r=>r.error).length
  verify('more than 32 waiting jobs are refused',fill.filter(r=>r.error).length>=6)
  for(const r of fill)if(r.result)await core.call('desktop.jobs.cancel',{job_id:r.result.job_id})
  // ⑨ Core and hostd lived through it all
  verify('the desktop is still served',!!(await core.must('desktop.profiles.get')).profile.head_revision)
  report({ok:true,checks,facts});core.close()
}catch(error){report({ok:false,checks,facts,error:String(error)});process.exitCode=1}
