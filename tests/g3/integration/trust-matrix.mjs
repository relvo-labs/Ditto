import {copyFileSync,existsSync,mkdirSync,writeFileSync} from 'node:fs'
import {dirname,join} from 'node:path'
import {execFileSync} from 'node:child_process'

// Actual installed archives, not mock validation reports. Arbitrary sources
// must never enter a desktop host, even when isolated templates can run.
export async function trustMatrix(core,head,verify){
 const root=join(dirname(process.env.DITTO_G3_TEST_OUT),'untrusted')
 mkdirSync(root)
 const results=[]
 for(const kind of ['qml','node','native']){
  const source=join(root,kind),witness=join(root,kind+'.executed'),id='local.untrusted.'+kind
  mkdirSync(source)
  const manifest={manifest_version:1,id,version:'1.0.0',name:id,author:'Ditto test',license:'UNLICENSED',source:'generated',trust_level:'untrusted',required_protocol_version:'^0.3',plugin_kind:kind==='qml'?'qml_provider':'service',host_kind:kind==='qml'?'qml':kind==='node'?'cordis':'native',slots:[kind==='qml'?'ui.generated_panel':'svc.tasks'],hot_swap:'instant',health:{timeout_ms:2000},cleanup:{timeout_ms:2000},idle_policy:'resident'}
  if(kind==='qml'){
   manifest.qml_entry='Panel.qml'
   writeFileSync(join(source,'Panel.qml'),'import QtQuick\nimport Quickshell.Io\nItem { Process { command: ["touch", '+JSON.stringify(witness)+']; running: true } }\n')
  }else if(kind==='node'){
   manifest.entry='index.mjs'
   writeFileSync(join(source,'index.mjs'),"import {writeFileSync} from 'node:fs'; writeFileSync("+JSON.stringify(witness)+",'executed'); export default () => {};\n")
  }else{
   manifest.entry='candidate'
   copyFileSync('/usr/bin/true',join(source,'candidate')) // Real ELF; native is not a host kind.
  }
  writeFileSync(join(source,'manifest.json'),JSON.stringify(manifest))
  const archive=join(root,kind+'.dittopkg')
  execFileSync('tar',['--zstd','-cf',archive,'-C',source,'.'])
  const installed=await core.must('desktop.plugins.install',{path:archive,idempotency_key:'untrusted-'+kind})
  let refusal
  if(kind==='native'){
   verify('untrusted native ELF is refused during installation',installed.state==='failed'&&installed.error_key==='install.invalid_package')
   refusal={install_state:installed.state,error_key:installed.error_key}
  }else{
   verify('untrusted '+kind+' archive installs without executing',installed.state==='succeeded'&&!existsSync(witness))
   const response=await core.call('desktop.changes.propose',{base_revision:head,ops:[{op:'add_entry',entry:{package:id,version:'1.0.0',host:manifest.host_kind},slot:manifest.slots[0]}],idempotency_key:'untrusted-activate-'+kind})
   verify('untrusted '+kind+' never enters a desktop host',response.error?.name==='preflight_rejected')
   const change=await core.must('desktop.changes.get',{change_id:response.error.data.change_id})
   verify('untrusted '+kind+' rejection has authoritative trust-policy evidence',change.state==='rejected'&&change.operations.length===0&&change.reasons.some(r=>r.detail.why==='trust_policy'))
   refusal={change_id:change.change_id,state:change.state,reasons:change.reasons}
  }
  verify('untrusted '+kind+' leaves revision and execution witness unchanged',(await core.must('desktop.profiles.get')).profile.head_revision===head&&!existsSync(witness))
  results.push({kind,installed,refusal,witness_exists:existsSync(witness)})
 }
 return results
}
