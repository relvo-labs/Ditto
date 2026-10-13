import {readFileSync,writeFileSync} from 'node:fs'
import {connect,sleep} from '../../g1/lib/core-client.mjs'
const checks=[],facts={}
const verify=(name,value)=>{if(!value)throw new Error('check failed: '+name);checks.push(name)}
const eventually=async(fn)=>{for(let i=0;i<600;i++){const v=await fn();if(v)return v;await sleep(50)}throw new Error('condition timed out')}
const report=r=>writeFileSync(process.env.DITTO_G3_TEST_OUT,JSON.stringify(r))
try{
  const core=await connect()
  await eventually(async()=>(await core.call('desktop.profiles.get',{})).result)
  const listing=await core.must('desktop.capabilities.list')
  verify('official development capabilities are discoverable',listing.capabilities.filter(c=>c.capability_id.startsWith('desktop.plugins.development.')).length===9)
  const head=(await core.must('desktop.profiles.get')).profile.head_revision
  for(const example of ['tasks-summary','workspace-actions']){
    const description=JSON.parse(readFileSync(new URL(`../../../crates/ditto-generation/examples/${example}.json`,import.meta.url),'utf8'))
    const params={description,request_summary:'Create '+description.title,idempotency_key:'create-'+example}
    const artifact=await core.must('desktop.plugins.development.create',params)
    verify(example+' source bundle complete',!!artifact.source_files['manifest.json']&&!!artifact.source_files['description.json']&&!!artifact.dependencies.template_sha256&&!!artifact.config_schema)
    verify(example+' create idempotent',(await core.must('desktop.plugins.development.create',params)).artifact_id===artifact.artifact_id)
    const premature=await core.call('desktop.plugins.development.publish',{artifact_id:artifact.artifact_id})
    verify(example+' unvalidated publish denied',!!premature.error)
    const job=await core.must('desktop.plugins.development.validate',{artifact_id:artifact.artifact_id,idempotency_key:'validate-'+example})
    const finished=await eventually(async()=>{const j=await core.must('desktop.jobs.get',{job_id:job.job_id});return ['succeeded','failed','cancelled'].includes(j.state)?j:false})
    facts[example]=finished
    verify(example+' real isolated worker completed',finished.state==='succeeded')
    const validated=await core.must('desktop.plugins.development.get',{artifact_id:artifact.artifact_id})
    facts[example+'-artifact']=validated
    if(process.env.DITTO_G3_EXPECT_OLD_ABI==='1') {
      verify(example+' old kernel is inspection only',validated.state==='inspect_only'&&validated.validation.boundary.enforcement==='partial'&&validated.validation.stages.every(s=>s.result==='not_run'));
      verify(example+' partial isolation cannot publish',!!(await core.call('desktop.plugins.development.publish',{artifact_id:artifact.artifact_id})).error);
      continue;
    }
    verify(example+' five stages passed under full production policy',validated.state==='validated'&&validated.validation.boundary.enforcement==='full'&&validated.validation.boundary.process_exec_blocked&&validated.validation.stages.every(s=>s.result==='passed'))
    const published=await core.must('desktop.plugins.development.publish',{artifact_id:artifact.artifact_id})
    verify(example+' published after validation',published.state==='published')
    verify(example+' package readback is untrusted fixed description',(await core.must('desktop.plugins.get',{package_id:description.plugin_id,version:description.version})).package.source==='generated')
    const activated=await core.must('desktop.plugins.development.activate',{artifact_id:artifact.artifact_id,base_revision:head,idempotency_key:'activation-'+example})
    verify(example+' missing Shell aborts safely',activated.state==='aborted')
    const replay=await core.must('desktop.plugins.development.activate',{artifact_id:artifact.artifact_id,base_revision:head,idempotency_key:'activation-'+example});
    verify(example+' aborted activation retry returns same record',replay.change_id===activated.change_id&&replay.state==='aborted');
    const different=await core.call('desktop.plugins.development.activate',{artifact_id:artifact.artifact_id,base_revision:'rev-other',idempotency_key:'activation-'+example});
    verify(example+' activation key cannot change target',different.error?.name==='conflict');

    verify(example+' desktop head unchanged',(await core.must('desktop.profiles.get')).profile.head_revision===head)
  }
  const raw=await core.call('desktop.plugins.development.create',{description:{format_version:1,plugin_id:'local.generated.raw',version:'0.1.0',title:'raw',width:320,accent:'#8B5CF6',content:{template:'free_qml',source:'import Quickshell.Io'}},request_summary:'bad',idempotency_key:'raw'})
  verify('arbitrary QML rejected by formal contract',raw.error?.name==='invalid_params')
  const bypass=await core.call('desktop.jobs.submit',{kind:'generation.validate',params:{},idempotency_key:'bypass'})
  verify('generation jobs cannot bypass development authorization',bypass.error?.name==='invalid_params')
  report({ok:true,checks,facts});core.close()
}catch(error){report({ok:false,checks,facts,error:String(error)});process.exitCode=1}
