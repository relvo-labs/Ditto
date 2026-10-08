import {readFileSync,writeFileSync,readdirSync} from 'node:fs'
import {connect,sleep} from '../../g1/lib/core-client.mjs'
const report=r=>writeFileSync(process.env.DITTO_G2_TEST_OUT,JSON.stringify(r))
const agentPids=()=>{
  const out=[];const kids=p=>{try{return readdirSync(`/proc/${p}/task`).flatMap(t=>{try{return readFileSync(`/proc/${p}/task/${t}/children`,'utf8').trim().split(' ').filter(Boolean).map(Number)}catch{return []}})}catch{return []}}
  const walk=p=>{for(const k of kids(p)){let c='';try{c=readFileSync(`/proc/${k}/cmdline`,'utf8')}catch{};if(/ditto-agentd|ditto-confine|app-server/.test(c))out.push(k);walk(k)}}
  walk(process.ppid);return out
}
const pct=(xs,p)=>{const s=[...xs].sort((a,b)=>a-b);return s[Math.min(s.length-1,Math.ceil(p*s.length)-1)]}
try{
  const core=await connect()
  for(let i=0;i<300;i++){if((await core.call('agent.sessions.create',{title:'probe',idempotency_key:'boot'})).error?.data?.reason!=='recovering')break;await sleep(50)}
  const s=await core.must('agent.settings.describe');const {_meta,...p}=s
  await core.must('agent.settings.patch',{expected_revision:s.revision,settings:{...p,enabled:true}})
  const samples=[]
  for(let i=0;i<Number(process.env.DITTO_G2_RUNS);i++){
    // Cold: no Agent process of any kind before the clock starts.
    for(let w=0;w<200&&agentPids().length;w++)await sleep(25)
    if(agentPids().length)throw new Error('run '+i+': an Agent process survived the previous stop')
    const t0=performance.now()
    await core.must('agent.runtime.ensure')
    let ready
    for(;;){const r=await core.must('agent.runtime.get');if(r.phase==='ready'){ready=r;break};if(r.phase==='failed')throw new Error('failed: '+r.failure_reason);await sleep(5)}
    const tReady=performance.now()
    const status=await core.must('agent.providers.status',{provider:'codex-app-server'})
    const tAuth=performance.now()
    if(!ready.isolation_verified||!status.authenticated)throw new Error('run '+i+': not an authenticated confined backend')
    samples.push({ready_ms:Math.round(tReady-t0),authenticated_ms:Math.round(tAuth-t0)})
    await core.must('agent.runtime.stop')
    for(let w=0;w<400;w++){if((await core.must('agent.runtime.get')).phase==='stopped')break;await sleep(10)}
  }
  const auth=samples.map(s=>s.authenticated_ms),ready=samples.map(s=>s.ready_ms)
  const summary={runs:samples.length,authenticated_p50_ms:pct(auth,0.5),authenticated_p95_ms:pct(auth,0.95),authenticated_max_ms:Math.max(...auth),ready_p95_ms:pct(ready,0.95),target_p95_ms:2000}
  report({ok:summary.authenticated_p95_ms<=2000,summary,samples});core.close()
}catch(error){report({ok:false,error:String(error)});process.exitCode=1}
