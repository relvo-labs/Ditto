// NFR-13 (EX2-12) on the reference machine's logged-in Ditto session: 30
// cold Agent starts with the real, signed-in Codex backend, through the
// verification relay (install-session.sh --verification-relay).
//
//   node cold-start-session.mjs [runs=30] [answer runs=5]
//
// Each run starts from no Agent process of this user at all (controller,
// ditto-confine, app-server). The clock starts at `agent.runtime.ensure`, the
// call the Shell makes when the person opens the chat, and stops when Core
// reports the controller ready with its backend confined and the provider
// answers authenticated. Then, reported apart and from cold as well, the
// first complete model answer to a one-word request without tools (the relay
// cannot follow the stream, so this is the whole answer, not the first
// token). Run it while nothing else uses the Agent.
import {createConnection} from 'node:net'
import {readFileSync,readdirSync,writeFileSync,mkdirSync} from 'node:fs'
import {execFileSync} from 'node:child_process'
import {resolve} from 'node:path'
import {fileURLToPath} from 'node:url'

const runs=Number(process.argv[2]??30)
const answerRuns=Number(process.argv[3]??5)
const workspace=fileURLToPath(new URL('../../../',import.meta.url))
const relayPath=process.env.DITTO_G1_RELAY??`/run/user/${process.getuid()}/ditto/verify-relay.sock`
const sleep=ms=>new Promise(r=>setTimeout(r,ms))
function call(method,params={}){
  return new Promise((done,fail)=>{
    const socket=createConnection(relayPath);let buffer=''
    socket.on('data',chunk=>{buffer+=chunk;const i=buffer.indexOf('\n');if(i>=0){socket.end();done(JSON.parse(buffer.slice(0,i)))}})
    socket.on('error',fail)
    socket.write(JSON.stringify({method,params})+'\n')
  })
}
async function must(method,params={}){const r=await call(method,params);if(r.error)throw new Error(`${method}: ${r.error.name} ${r.error.message??''}`);return r.result}
const uid=process.getuid()
function agentPids(){
  const out=[]
  for(const pid of readdirSync('/proc').filter(n=>/^\d+$/.test(n))){
    try{
      if(!readFileSync(`/proc/${pid}/status`,'utf8').match(new RegExp(`^Uid:\\s+${uid}\\b`,'m')))continue
      // By program, not by command line: Core's own arguments name the Agent.
      const argv=readFileSync(`/proc/${pid}/cmdline`,'utf8').split('\0')
      const program=argv[0].split('/').at(-1)
      if(['ditto-confine','codex','xdg-dbus-proxy','ditto-dbus-proxy'].includes(program)||argv[1]?.endsWith('ditto-agentd.mjs'))out.push(Number(pid))
    }catch{}
  }
  return out
}
const pct=(xs,p)=>{const s=[...xs].sort((a,b)=>a-b);return s[Math.min(s.length-1,Math.ceil(p*s.length)-1)]}
async function stopCold(i){
  await must('agent.runtime.stop')
  // An ensure while Core is still stopping the generation starts nothing.
  for(let w=0;w<400;w++){if((await must('agent.runtime.get')).phase==='stopped')break;await sleep(25)}
  for(let w=0;w<400&&agentPids().length;w++)await sleep(25)
  if(agentPids().length)throw new Error(`run ${i}: an Agent process survived the stop: ${agentPids()}`)
}
async function ready(){
  for(;;){const r=await must('agent.runtime.get');if(r.phase==='ready')return r;if(r.phase==='failed')throw new Error('failed: '+r.failure_reason);await sleep(5)}
}

// The person's choice stands: an Agent turned off is not turned on here,
// unless DITTO_MEASURE_ENABLE_AGENT=1 (a disposable VM).
const settings=await must('agent.settings.describe')
if(!settings.enabled){
  if(process.env.DITTO_MEASURE_ENABLE_AGENT!=='1'){console.log(JSON.stringify({ok:false,not_run:'the Agent is turned off in AI settings'}));process.exit(2)}
  const {_meta,...p}=settings;await must('agent.settings.patch',{expected_revision:settings.revision,settings:{...p,enabled:true}})
}
await must('agent.runtime.ensure');await ready()
if(!(await must('agent.providers.status',{provider:'codex-app-server'})).authenticated){console.log(JSON.stringify({ok:false,not_run:'the Codex subscription is not signed in'}));process.exit(2)}

const samples=[]
for(let i=0;i<runs;i++){
  await stopCold(i)
  const t0=performance.now()
  await must('agent.runtime.ensure')
  const r=await ready()
  const tReady=performance.now()
  const status=await must('agent.providers.status',{provider:'codex-app-server'})
  const tAuth=performance.now()
  if(!r.isolation_verified||!status.authenticated)throw new Error(`run ${i}: not an authenticated confined backend`)
  samples.push({ready_ms:Math.round(tReady-t0),authenticated_ms:Math.round(tAuth-t0)})
}
const answers=[]
const stamp=new Date().toISOString().replace(/[:.]/g,'-')
for(let i=0;i<answerRuns;i++){
  await stopCold(`answer ${i}`)
  const t0=performance.now()
  await must('agent.runtime.ensure')
  const session=await must('agent.sessions.create',{title:'cold start measurement',idempotency_key:`cold-start-${stamp}-${i}`})
  const turn=await must('agent.turns.submit',{session_id:session.session_id,client_message_id:`cold-start-${stamp}-${i}`,text:'只回覆「好」，不要使用任何工具。',contexts:[]})
  let state
  for(;;){state=(await must('agent.turns.get',{turn_id:turn.turn_id})).state;if(['succeeded','failed','cancelled','unknown','partial'].includes(state))break;await sleep(20)}
  answers.push({answer_ms:Math.round(performance.now()-t0),state})
  await call('agent.sessions.delete',{session_id:session.session_id})
}
const auth=samples.map(s=>s.authenticated_ms),readyMs=samples.map(s=>s.ready_ms),done=answers.filter(a=>a.state==='succeeded').map(a=>a.answer_ms)
const summary={runs:samples.length,authenticated_p50_ms:pct(auth,0.5),authenticated_p95_ms:pct(auth,0.95),authenticated_max_ms:Math.max(...auth),ready_p95_ms:pct(readyMs,0.95),target_p95_ms:2000,
  first_answer_runs:answers.length,first_answer_succeeded:done.length,first_answer_p50_ms:done.length?pct(done,0.5):null,first_answer_max_ms:done.length?Math.max(...done):null}
const sha=execFileSync('git',['-C',workspace,'rev-parse','HEAD'],{encoding:'utf8'}).trim()
const out=resolve(workspace,`artifacts/g2/cold-start-session-${stamp}.json`)
mkdirSync(resolve(workspace,'artifacts/g2'),{recursive:true})
writeFileSync(out,JSON.stringify({ok:summary.authenticated_p95_ms<=2000,summary,samples,answers,git:sha,
  environment:process.env.DITTO_MEASURE_ENVIRONMENT??'reference machine, logged-in Ditto session, real signed-in Codex backend',
  clock:'agent.runtime.ensure → ready + provider authenticated (relay round trips included); answers: ensure → turn succeeded, whole answer'},null,1))
console.log(JSON.stringify({ok:summary.authenticated_p95_ms<=2000,summary,artifact:out}))
