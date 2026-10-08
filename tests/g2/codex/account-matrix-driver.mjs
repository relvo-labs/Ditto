// EX2-19 / G2-QA-09 on the real subscription, after the person has signed
// in (tests/g2/codex/subscription.mjs). Launched by Core through
// subscription.mjs with DITTO_G2_TASK=matrix. Every case reads Core back;
// what cannot be produced here (a second account, an exhausted quota) is
// reported not_run, never passed.
//   DITTO_G2_MATRIX_LOGOUT=1 also signs out at the end (the person signs in
//   again for the next run) and checks a cancelled sign-in.
import {writeFileSync,existsSync} from 'node:fs'
import {join} from 'node:path'
import {createConnection} from 'node:net'
import {connect,sleep} from '../../g1/lib/core-client.mjs'

const cases=[],facts={}
const record=(name,status,detail)=>cases.push({case:name,status,...(detail!==undefined?{detail}:{})})
const eventually=async(fn,tries,ms=200)=>{for(let i=0;i<tries;i++){const v=await fn();if(v)return v;await sleep(ms)}return false}
const terminal=['succeeded','failed','cancelled','unknown','partial']
const report=r=>writeFileSync(process.env.DITTO_G2_TEST_OUT,JSON.stringify(r))
try{
  const core=await connect()
  await eventually(async()=>(await core.call('agent.sessions.create',{title:'probe',idempotency_key:'matrix-probe'})).error?.data?.reason!=='recovering',300)
  let settings=await core.must('agent.settings.describe')
  if(!settings.enabled){const {_meta,...s}=settings;settings=await core.must('agent.settings.patch',{expected_revision:settings.revision,settings:{...s,enabled:true}})}
  await core.must('agent.runtime.ensure')
  await eventually(async()=>(await core.must('agent.runtime.get')).phase==='ready',150)
  const status=await core.must('agent.providers.status',{provider:'codex-app-server'})
  if(!status.authenticated){report({ok:false,not_run:'not signed in; run subscription.mjs first'});process.exit(0)}
  facts.models=status.models.map(m=>({id:m.id,efforts:m.reasoning_efforts}))
  facts.quota=status.rate_limits??null
  record('models and efforts listed from the account',status.models.length>0?'pass':'fail',facts.models.length)
  record('quota windows visible',status.rate_limits&&(status.rate_limits.primary||status.rate_limits.secondary)?'pass':'fail',facts.quota)
  record('quota exhausted refuses a turn without falling back','not_run','cannot exhaust a real quota on purpose; covered by the rate_limited unit and Core paths')
  record('switching to a second account','not_run','needs a second ChatGPT account signed in by its owner')
  const codexHome=join(process.env.DITTO_DATA_DIR,'state/agent/backend/codex')
  record('no plaintext credential file',!existsSync(join(codexHome,'auth.json'))?'pass':'fail')

  const turn=async(session,key,text,limit=600)=>{
    const t=await core.must('agent.turns.submit',{session_id:session.session_id,client_message_id:key,text})
    const done=await eventually(async()=>{const x=await core.must('agent.turns.get',{turn_id:t.turn_id});return terminal.includes(x.state)?x:false},limit,500)
    return done||{...t,state:'timeout'}
  }
  const answers=async session=>(await core.must('agent.sessions.read',{session_id:session.session_id,offset:0,limit:200})).events.filter(e=>e.type==='assistant/message').map(e=>String(e.data.text??''))
  const head=async()=>(await core.must('desktop.profiles.get')).profile.head_revision

  // ① history from Core rehydrates a new generation; nothing is replayed.
  const word='ditto-'+Math.random().toString(36).slice(2,8)
  const s1=await core.must('agent.sessions.create',{title:'matrix history',idempotency_key:'matrix-history-'+Date.now()})
  const t1=await turn(s1,'h1-'+Date.now(),`請記住這個代號：${word}。只要回答「記住了」，不要呼叫任何工具。`)
  const before=(await core.must('agent.runtime.get')).generation
  await core.must('agent.runtime.stop')
  await eventually(async()=>(await core.must('agent.runtime.get')).phase==='stopped',150)
  const revisionBefore=await head()
  const t2=await turn(s1,'h2-'+Date.now(),'我剛才請你記住的代號是什麼？只回答代號，不要呼叫任何工具。')
  const after=(await core.must('agent.runtime.get')).generation
  const said=await answers(s1)
  const trace=await core.must('agent.turns.trace',{turn_id:t2.turn_id})
  facts.history={first:t1.state,second:t2.state,generations:[before,after],answer:said.at(-1)}
  record('a new Agent generation answers from Core history',t2.state==='succeeded'&&after>before&&said.at(-1).includes(word)?'pass':'fail',facts.history)
  record('rehydration replays no tool and changes nothing',trace.tools.length===0&&(await head())===revisionBefore?'pass':'fail',{tools:trace.tools.length})

  // ② stop during a real model call.
  const s2=await core.must('agent.sessions.create',{title:'matrix stop',idempotency_key:'matrix-stop-'+Date.now()})
  const r0=await head()
  const long=await core.must('agent.turns.submit',{session_id:s2.session_id,client_message_id:'stop-'+Date.now(),text:'請寫一篇大約一千字、介紹桌面環境歷史的文章。不要呼叫任何工具。'})
  await sleep(1500)
  const stopAt=Date.now()
  await core.must('agent.turns.cancel',{turn_id:long.turn_id})
  const stopped=await eventually(async()=>{const x=await core.must('agent.turns.get',{turn_id:long.turn_id});return terminal.includes(x.state)?x:false},120,250)
  facts.stop={state:stopped&&stopped.state,ms:Date.now()-stopAt}
  record('stop during a real model answer ends the turn cancelled',stopped&&stopped.state==='cancelled'&&(await head())===r0?'pass':'fail',facts.stop)

  // ③ the backend dies during a real turn; the next generation is still signed in.
  const s3=await core.must('agent.sessions.create',{title:'matrix crash',idempotency_key:'matrix-crash-'+Date.now()})
  await core.must('agent.runtime.ensure');await eventually(async()=>(await core.must('agent.runtime.get')).phase==='ready',150)
  const runtime=await core.must('agent.runtime.get')
  const crashing=await core.must('agent.turns.submit',{session_id:s3.session_id,client_message_id:'crash-'+Date.now(),text:'請寫一篇大約一千字的短文。不要呼叫任何工具。'})
  await sleep(1500)
  try{process.kill(runtime.backend_pid,'SIGKILL')}catch{}
  const crashed=await eventually(async()=>{const x=await core.must('agent.turns.get',{turn_id:crashing.turn_id});return terminal.includes(x.state)?x:false},120,250)
  await core.must('agent.runtime.ensure');await eventually(async()=>(await core.must('agent.runtime.get')).phase==='ready',150)
  const again=await core.must('agent.providers.status',{provider:'codex-app-server'})
  facts.crash={state:crashed&&crashed.state,reason:crashed&&crashed.error_reason,authenticated_after:again.authenticated}
  record('a backend crash ends the turn without success; the sign-in survives',crashed&&crashed.state!=='succeeded'&&again.authenticated?'pass':'fail',facts.crash)

  // ④ sign out, then a cancelled sign-in (opt-in: the person signs in again).
  if(process.env.DITTO_G2_MATRIX_LOGOUT==='1'){
    await core.must('agent.providers.logout',{provider:'codex-app-server'})
    const out=await core.must('agent.providers.status',{provider:'codex-app-server'})
    record('sign-out leaves the backend unauthenticated',!out.authenticated?'pass':'fail')
    const s4=await core.must('agent.sessions.create',{title:'matrix signed out',idempotency_key:'matrix-out-'+Date.now()})
    const refused=await turn(s4,'out-'+Date.now(),'你好')
    record('signed out, a turn fails and nothing falls back to an API key',refused.state==='failed'&&refused.error_reason==='provider_unavailable'?'pass':'fail',{state:refused.state,reason:refused.error_reason})
    const login=await core.must('agent.providers.login',{provider:'codex-app-server'})
    await core.must('agent.providers.cancel_login',{provider:'codex-app-server',login_id:login.login_id})
    const port=Number(new URL(new URL(login.auth_url).searchParams.get('redirect_uri')).port)
    const closed=await new Promise(resolve=>{const c=createConnection(port,'127.0.0.1');c.on('connect',()=>{c.destroy();resolve(false)});c.on('error',()=>resolve(true))})
    const still=await core.must('agent.providers.status',{provider:'codex-app-server'})
    record('a cancelled sign-in closes its callback and signs nobody in',closed&&!still.authenticated?'pass':'fail',{port})
  }else record('sign-out and cancelled sign-in','not_run','set DITTO_G2_MATRIX_LOGOUT=1; the person signs in again afterwards')
  await core.must('agent.runtime.stop')
  report({ok:cases.every(c=>c.status!=='fail'),checks:cases.filter(c=>c.status==='pass').map(c=>c.case),cases,facts});core.close()
}catch(error){report({ok:false,cases,facts,error:String(error?.stack??error)});process.exitCode=1}
