import {readFileSync,writeFileSync,existsSync,readdirSync} from 'node:fs'
import {connect,sleep} from '../../g1/lib/core-client.mjs'

const checks=[],facts={}
const verify=(n,v)=>{if(!v)throw new Error('check failed: '+n);checks.push(n)}
const eventually=async(fn,tries=300,ms=100)=>{for(let i=0;i<tries;i++){const v=await fn();if(v)return v;await sleep(ms)}return false}
const report=r=>writeFileSync(process.env.DITTO_G2_TEST_OUT,JSON.stringify(r))
const core_pid=process.ppid
// Every process under Core, by command line.
function descendants(pid=core_pid){
  const out=[]
  const kids=p=>{try{return readdirSync(`/proc/${p}/task`).flatMap(t=>{try{return readFileSync(`/proc/${p}/task/${t}/children`,'utf8').trim().split(' ').filter(Boolean).map(Number)}catch{return []}})}catch{return []}}
  const walk=p=>{for(const k of kids(p)){let cmd='';try{cmd=readFileSync(`/proc/${k}/cmdline`,'utf8').replaceAll('\0',' ')}catch{};out.push({pid:k,cmd});walk(k)}}
  walk(pid);return out
}
const agentProcesses=()=>descendants().filter(p=>/ditto-agentd|ditto-confine|app-server|dbus-proxy/.test(p.cmd))
const pss=pid=>{try{return Number(readFileSync(`/proc/${pid}/smaps_rollup`,'utf8').match(/^Pss:\s+(\d+)/m)[1])}catch{return 0}}
try{
  const core=await connect()
  await eventually(async()=>(await core.call('agent.sessions.create',{title:'probe',idempotency_key:'boot'})).error?.data?.reason!=='recovering')
  const s=await core.must('agent.settings.describe');const {_meta,...p}=s
  await core.must('agent.settings.patch',{expected_revision:s.revision,settings:{...p,enabled:true}})
  const runtime=()=>core.must('agent.runtime.get')
  const ready=async()=>eventually(async()=>{const r=await runtime();return r.phase==='ready'?r:false},200)
  const stopped=async()=>eventually(async()=>{const r=await runtime();return r.phase==='stopped'?r:false},300)
  if(process.env.DITTO_G2_MODE==='quick'){
    // ① ten wake-ups at once: one generation, one controller, one backend
    const before=(await runtime()).generation
    const answers=await Promise.all(Array.from({length:10},()=>core.call('agent.runtime.ensure',{})))
    verify('ten concurrent wake-ups all answered',answers.every(a=>!a.error))
    const r=await ready()
    verify('they made exactly one generation',r&&r.generation===before+1)
    const procs=agentProcesses()
    facts.processes=procs.map(p=>p.cmd.split(' ')[0].split('/').pop())
    verify('one controller, one confined app-server: '+JSON.stringify(facts.processes),procs.filter(p=>/ditto-agentd/.test(p.cmd)).length===1&&procs.filter(p=>/app-server/.test(p.cmd)&&!/ditto-confine/.test(p.cmd)).length===1)
    await core.must('agent.runtime.stop');await stopped()
    // ② 100 start/stop cycles
    const corePss=[]
    const cycles=Number(process.env.DITTO_G2_CYCLES??100)
    facts.series=[]
    for(let i=0;i<cycles;i++){
      await core.must('agent.runtime.ensure')
      if(!await ready())throw new Error('cycle '+i+': not ready')
      await core.must('agent.runtime.stop')
      if(!await stopped())throw new Error('cycle '+i+': did not stop')
      if(i===9||i===cycles-1)corePss.push(pss(core_pid))
      if(i%10===9){
        const status=readFileSync(`/proc/${core_pid}/status`,'utf8')
        facts.series.push({pss:pss(core_pid),threads:Number(status.match(/^Threads:\s+(\d+)/m)[1]),fds:readdirSync(`/proc/${core_pid}/fd`).length})
      }
    }
    await sleep(500)
    {
      const {readlinkSync}=await import('node:fs')
      const counts={}
      for(const fd of readdirSync(`/proc/${core_pid}/fd`)){let t='';try{t=readlinkSync(`/proc/${core_pid}/fd/${fd}`)}catch{};const k=t.replace(/\[\d+\]/,'[]').replace(/\/proc\/\d+/,'/proc/N');counts[k]=(counts[k]??0)+1}
      facts.fd_kinds=counts
      const names={}
      for(const t of readdirSync(`/proc/${core_pid}/task`)){let n='';try{n=readFileSync(`/proc/${core_pid}/task/${t}/comm`,'utf8').trim()}catch{};names[n]=(names[n]??0)+1}
      facts.thread_names=names
    }
    if(process.env.DITTO_G2_HOLD){writeFileSync(process.env.DITTO_G2_TEST_OUT+'.hold',String(core_pid));await sleep(Number(process.env.DITTO_G2_HOLD)*1000)}
    facts.leftover=agentProcesses().map(p=>p.cmd.slice(0,80))
    verify('100 cycles leave no Agent process behind',facts.leftover.length===0)
    facts.core_pss_kib={after10:corePss[0],after100:corePss[1]}
    verify('Core memory flat across cycles (≤10% growth after warm-up): '+JSON.stringify(facts.core_pss_kib),corePss[1]<=corePss[0]*1.1)
    verify('the desktop host survived every cycle',descendants().some(p=>/ditto-hostd/.test(p.cmd)))
    facts.generation=(await runtime()).generation
  }else if(process.env.DITTO_G2_MODE==='activity'){
    // ③ shortened idle limit (20 s): a 45 s turn keeps its Agent; once it
    // ends, the Agent leaves about 20 s later
    const session=await core.must('agent.sessions.create',{title:'long',idempotency_key:'long'})
    const long=await core.must('agent.turns.submit',{session_id:session.session_id,client_message_id:'long',text:'long-task'})
    await ready()
    await sleep(35_000)
    verify('a turn running longer than the idle limit keeps its Agent',(await runtime()).phase==='ready'&&(await core.must('agent.turns.get',{turn_id:long.turn_id})).state==='running')
    const done=await eventually(async()=>{const t=await core.must('agent.turns.get',{turn_id:long.turn_id});return ['succeeded','failed','cancelled'].includes(t.state)?t:false},400)
    verify('the long turn finished on its own',done&&done.state==='succeeded')
    const endedAt=Date.now()
    await sleep(15_000)
    verify('not released before the idle limit after the turn',(await runtime()).phase==='ready')
    const gone=await eventually(async()=>{const r=await runtime();return r.phase==='stopped'?r:false},300,100)
    facts.release_after_turn_s=Math.round((Date.now()-endedAt)/100)/10
    verify('released within 10 s after the idle limit: '+facts.release_after_turn_s,gone&&facts.release_after_turn_s>=20&&facts.release_after_turn_s<=30)
    await sleep(500)
    verify('no Agent process left',agentProcesses().length===0)
  }else{
    // ④ real time: an Agent with nothing to do leaves 5 min after it was
    // last used, within 10 s
    await core.must('agent.runtime.ensure')
    await ready()
    const from=Date.now()
    await sleep(290_000)
    verify('still there just before five idle minutes',(await runtime()).phase==='ready')
    const gone=await eventually(async()=>{const r=await runtime();return r.phase==='stopped'?r:false},300,100)
    facts.idle_release_s=Math.round((Date.now()-from)/100)/10
    verify('released between 300 and 310 s after it was last used: '+facts.idle_release_s,gone&&facts.idle_release_s>=300&&facts.idle_release_s<=310)
    await sleep(500)
    verify('no Agent process left after the idle exit',agentProcesses().length===0)
  }
  report({ok:true,checks,facts});core.close()
}catch(error){report({ok:false,checks,facts,error:String(error)});process.exitCode=1}
