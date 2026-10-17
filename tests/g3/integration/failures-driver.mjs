// Real durable Core pipeline and real fixed Qt faults. Test-only host binary;
// no Shell/physical claim, no invented reports and no arbitrary-source API.
import {readFileSync,writeFileSync} from 'node:fs'
import {connect,sleep} from '../../g1/lib/core-client.mjs'
const checks=[],facts={}
const verify=(name,yes)=>{if(!yes)throw Error(name);checks.push(name)}
try{
 const core=await connect(),head=(await core.must('desktop.profiles.get')).profile.head_revision
 const cases=process.env.DITTO_G3_SKIP_TIMEOUT==='1'?['syntax','illegal-import']:['syntax','illegal-import','timeout']
 for(const kind of cases){
  writeFileSync(process.env.DITTO_BINARIES+'/generation-fault.txt',kind)
  const description=JSON.parse(readFileSync('crates/ditto-generation/examples/tasks-summary.json','utf8'));description.plugin_id+='.'+kind.replaceAll('-','_')
  const artifact=await core.must('desktop.plugins.development.create',{description,request_summary:'Trusted fixed native failure '+kind,idempotency_key:kind})
  const started=await core.must('desktop.plugins.development.validate',{artifact_id:artifact.artifact_id,idempotency_key:kind})
  let job
  for(let i=0;i<600;i++){job=await core.must('desktop.jobs.get',{job_id:started.job_id});if(['succeeded','failed','cancelled'].includes(job.state))break;await sleep(100)}
  const a=await core.must('desktop.plugins.development.get',{artifact_id:artifact.artifact_id});facts[kind]={job,artifact:a}
  verify(kind+' is a real confined syntax failure',a.state==='failed'&&a.validation.boundary.enforcement==='full'&&a.validation.boundary.cleanup_complete&&a.validation.boundary.process_exec_blocked&&a.validation.stages[0].result==='failed'&&a.validation.stages.slice(1).every(s=>s.result==='not_run'))
  verify(kind+' cannot publish',(await core.call('desktop.plugins.development.publish',{artifact_id:a.artifact_id})).error)
  verify(kind+' retains immutable source',a.bundle_sha256===artifact.bundle_sha256&&JSON.stringify(a.source_files)===JSON.stringify(artifact.source_files))
  verify(kind+' preserves authoritative revision',(await core.must('desktop.profiles.get')).profile.head_revision===head)
  if(kind==='timeout')verify('timeout keeps actual interrupted-stage evidence',a.validation.stages[0].diagnostic==='native_runner_interrupted'&&a.validation.diagnostics.some(d=>d.startsWith('native_runner_interrupted:')))
 }
}catch(error){facts.error=String(error);process.exitCode=1}
finally{writeFileSync(process.env.DITTO_G3_TEST_OUT,JSON.stringify({ok:!process.exitCode,checks,facts}))}
