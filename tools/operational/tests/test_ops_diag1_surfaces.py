"""TEST ONLY diagnostics/read-only/namespace/expiry witnesses; no live OS."""
from contextlib import redirect_stdout,redirect_stderr
import errno,io,json,os
from pathlib import Path
import shutil,socket,subprocess,sys,tempfile,unittest
from unittest.mock import Mock,patch
from test_ops_diag1 import o,a,b,ID,SENTINEL
import g3_bridge_probe as probe
import g3_diagnostics as d

class DiagnosticSurfaces(unittest.TestCase):
 def setUp(self):
  temp=tempfile.TemporaryDirectory(prefix='TEST_ONLY_diag_edges_');self.addCleanup(temp.cleanup)
  self.base=Path(temp.name);self.root=self.base/('q'+ID);self.root.mkdir(mode=0o700)
 def state(self,**extra):
  value={'status':'blocked','reason':'BLOCKED_DEVICE_PAYLOAD_URL','login_complete':False,'model_verified':False,'native_stopped':True,'auth_lifecycle':'revoked'};value.update(extra)
  o.write(self.root/'auth-state.json',value)
 def test_D1_payload_field_classes(self):
  body={'qualification_id':ID,'flow_id':'a'*32,'auth_url':'https://auth.openai.com/codex/device','user_code':'TEST-1234','expires_at_ms':b.now_ms()+100000}
  cases=[({**body,'auth_url':SENTINEL},'URL'),({**body,'user_code':SENTINEL},'CODE'),({**body,'expires_at_ms':0},'EXPIRY'),({**body,'login_id':SENTINEL},'SHAPE')]
  for value,part in cases:
   with self.subTest(part=part),self.assertRaises(b.BridgeRefused) as error:b.login_payload(value,ID,'a'*32)
   self.assertEqual(error.exception.args[0],'BLOCKED_DEVICE_PAYLOAD_'+part);self.assertNotIn(SENTINEL,str(error.exception))
 def test_D1_tcp_types_errnos_never_export_exception_values(self):
  cases=[(ConnectionRefusedError(SENTINEL),'TCP_REFUSED'),(TimeoutError(SENTINEL),'TCP_TIMEOUT'),(ConnectionRefusedError(errno.ECONNREFUSED,SENTINEL),'TCP_REFUSED'),(OSError(errno.ENETUNREACH,SENTINEL),'NO_ROUTE'),(OSError(errno.EHOSTUNREACH,SENTINEL),'NO_ROUTE'),(OSError(errno.ECONNRESET,SENTINEL),'TCP_OTHER')]
  for failure,code in cases:
   client=b.Client.__new__(b.Client);client.config={'host':'127.0.0.1','port':50000,'expires_at_ms':b.now_ms()+10000};client.context=None
   conn=Mock();conn.connect.side_effect=failure
   out,err=io.StringIO(),io.StringIO()
   with self.subTest(code=code),patch.object(b.http.client,'HTTPSConnection',return_value=conn),redirect_stdout(out),redirect_stderr(err),self.assertRaises(b.BridgeRefused) as result:client.post('/status',{})
   self.assertEqual(result.exception.args[0],'BLOCKED_MTLS_'+code);self.assertNotIn(SENTINEL,str(result.exception)+out.getvalue()+err.getvalue())
 def test_D2_cleanup_failure_keeps_original_first_reason(self):
  self.state(status='starting',ops_sha='a'*40,realm='TEST_ONLY',native_stopped=False)
  o.write(self.root/'auth-prepare.json',{'flow_id':'a'*32});o.write(self.root/'auth-transport.json',{})
  def cleanup(root,host):
   state=o.read(root/'auth-state.json');state.update(status='needs_human',cleanup_errors=['normal_final_readback']);o.write(root/'auth-state.json',state)
  with patch.object(o,'verify_stage',return_value={'ops_sha':'a'*40}),patch.object(b,'Client',side_effect=b.BridgeRefused('BLOCKED_TRANSPORT_EXPIRED')),patch.object(a,'cleanup',side_effect=cleanup):a.supervisor(self.root,Mock())
  result=a.public_status(self.root)
  self.assertEqual(result['reason'],'BLOCKED_DEVICE_PAYLOAD_URL');self.assertEqual(result['status'],'needs_human')
  self.assertEqual(result['cleanup_errors'],['BLOCKED_CLEANUP_NORMAL_FINAL_READBACK'])
 def test_D3_typed_fields_and_legacy_cleanup_mapping(self):
  self.state(last_marker='login_requested',cleanup_errors=['ditto-g3-auth-q'+ID+'-agent.scope:stop','core_stop:budget_exhausted',SENTINEL])
  result=a.public_status(self.root)
  self.assertEqual(set(result['cleanup_errors']),{'BLOCKED_CLEANUP_SCOPE_STOP','BLOCKED_CLEANUP_BUDGET_EXHAUSTED','BLOCKED_UNLISTED_REASON'})
  self.assertNotIn(SENTINEL,json.dumps(result));self.assertEqual(result['last_marker'],'login_requested')
 def test_D3_unknown_nonstring_fields_fail_closed(self):
  self.state(reason={'value':SENTINEL},last_marker=[SENTINEL],auth_lifecycle={'value':SENTINEL})
  result=a.public_status(self.root);self.assertEqual(result['reason'],'BLOCKED_UNLISTED_REASON');self.assertNotIn(SENTINEL,json.dumps(result))
 def test_D3_missing_old_fields_are_not_inferred(self):
  self.state();value=o.read(self.root/'auth-state.json');value.pop('reason');value.pop('auth_lifecycle');o.write(self.root/'auth-state.json',value)
  result=a.public_status(self.root);self.assertEqual(result['reason'],'NOT_RECORDED');self.assertEqual(result['last_marker'],'not_recorded');self.assertEqual(result['auth_lifecycle'],'not_recorded')
 def test_D4_auth_reason_cli_old_sha_reads_only_and_starts_nothing(self):
  self.state(source=o.SOURCE,ops_sha='a'*40,qualification_id=ID);before=(self.root/'auth-state.json').read_bytes();out=io.StringIO()
  with patch.object(o,'BASE',self.base),patch.object(o.os,'getuid',return_value=1000),patch.object(Path,'home',return_value=Path('/home/neil')),patch.object(o.socket,'gethostname',return_value='neil-MotherBoard-Series'),patch.object(sys,'argv',['g3_ops.py','auth_reason','--id',ID]),patch.dict(os.environ,{'GITHUB_SHA':'b'*40}),patch.object(o,'verify_stage',return_value={'ops_sha':'a'*40}) as stage,patch.object(o,'Host') as host,patch.object(o.fcntl,'flock') as lock,redirect_stdout(out):o.main()
  stage.assert_called_once_with(self.root,read_only=True);host.assert_not_called();lock.assert_not_called()
  self.assertEqual((self.root/'auth-state.json').read_bytes(),before);self.assertEqual(json.loads(out.getvalue())['reason'],'BLOCKED_DEVICE_PAYLOAD_URL')
  self.assertEqual(set(p.name for p in self.root.iterdir()),{'auth-state.json'})
 def test_D4_stage_hash_failure_exports_no_state(self):
  self.state(reason=SENTINEL)
  with patch.object(o,'verify_stage',side_effect=o.Refused('BLOCKED_AUTH_BINDING')),patch.object(a,'public_status') as public,self.assertRaises(o.Refused):a.auth_reason(self.root)
  public.assert_not_called()
 def test_D4_auth_state_binding_mismatch_refuses(self):
  self.state(source=o.SOURCE,ops_sha='b'*40,qualification_id=ID)
  with patch.object(o,'verify_stage',return_value={'ops_sha':'a'*40}),self.assertRaisesRegex(o.Refused,'BLOCKED_AUTH_BINDING'):a.auth_reason(self.root)
 def test_D4_source_git_readonly_disables_optional_writes(self):
  with patch.object(o.subprocess,'check_output',side_effect=[o.SOURCE+'\n',b'']) as git:o.assert_source(self.root,read_only=True)
  self.assertTrue(all(call.kwargs['env']['GIT_OPTIONAL_LOCKS']=='0' for call in git.call_args_list))
 def test_D2_real_flow_markers_are_closed_and_secret_free(self):
  from test_ops_repair1 import RealmCore
  core=RealmCore();call=core.call;updates=[];out,err=io.StringIO(),io.StringIO()
  def rpc(method,*args,**kw):
   result=call(method,*args,**kw)
   if method=='agent.providers.login':result['login_id']=SENTINEL;result['user_code']='SEED-1234'
   return result
  core.call=rpc
  receipt={'qualification_id':ID,'flow_id':'a'*32,'expires_at_ms':b.now_ms()+180000}
  with patch.object(a,'minimal_probe',return_value={'test_only':True}),redirect_stdout(out),redirect_stderr(err):a.device_flow(core,Mock(),receipt,lambda **v:updates.append(v))
  markers=[v['last_marker'] for v in updates if 'last_marker' in v]
  self.assertEqual(markers,['native_ready','preauth_checked','login_requested','payload_validated','code_forwarded','awaiting_browser','login_complete','probe_done'])
  self.assertTrue(set(markers)<=d.MARKERS)
  text=json.dumps(updates)+out.getvalue()+err.getvalue()
  for secret in (SENTINEL,'SEED-1234','https://auth.openai.com/codex/device'):self.assertNotIn(secret,text)
 def test_E2_wrong_receiver_mode_never_touches_auth_receiver_keys(self):
  directory=self.base/'TEST_ONLY_parent';directory.mkdir(mode=0o700)
  (directory/'purpose.json').write_text('{"purpose":"auth"}')
  (directory/'server.key').write_text(SENTINEL)
  with patch.object(b,'QuietServer') as server,patch.object(b,'send_home') as sender,self.assertRaises(b.BridgeRefused):b.serve_receiver(directory,probe=True)
  self.assertEqual((directory/'server.key').read_text(),SENTINEL);server.assert_not_called();sender.assert_not_called()
 def prepare_probe(self):
  root=self.base/('p'+ID);host=Mock();host.command.return_value=subprocess.CompletedProcess([],0,'a'*40,'')
  with patch.dict(os.environ,{'GITHUB_SHA':'a'*40}):receipt=probe.prepare(root,ID,host)
  return root,host,receipt
 def test_E1_real_key_prepare_short_lease_public_receipt_and_idempotent_cleanup(self):
  root,host,receipt=self.prepare_probe()
  self.assertEqual(receipt['evidence_class'],'mtls-probe-prepare');self.assertNotIn('PRIVATE KEY',json.dumps(receipt))
  self.assertEqual((root/'client/client.key').stat().st_mode&0o777,0o600)
  self.assertTrue(any('--on-active=290' in call.args[0] and 'bridge_probe_cleanup' in call.args[0] for call in host.command.call_args_list))
  self.assertTrue(probe.cleanup(root));self.assertTrue(probe.cleanup(root))
  self.assertFalse((root/'client/client.key').exists())
 def test_E1_malformed_transport_erases_keys_without_any_connection(self):
  root,host,receipt=self.prepare_probe()
  with patch.dict(os.environ,{'GITHUB_SHA':'a'*40}),patch.object(b,'Client') as client:result=probe.run(root,host,SENTINEL)
  client.assert_not_called();self.assertEqual(result['result'],'BLOCKED_PROBE_INPUT');self.assertTrue(result['keys_erased']);self.assertNotIn(SENTINEL,json.dumps(result))
  with self.assertRaises(o.Refused):probe.run(root,host,'{}')
 def test_E1_cleanup_alias_never_deletes_outside_probe(self):
  root=self.base/'p223456789';root.mkdir(mode=0o700);outside=self.base/'TEST_ONLY_OTHER';outside.mkdir(mode=0o700);(outside/'client.key').write_text(SENTINEL);(root/'client').symlink_to(outside)
  with self.assertRaises(b.BridgeRefused):probe.cleanup(root)
  self.assertEqual((outside/'client.key').read_text(),SENTINEL)
 def test_E3_namespace_collision_refuses_both_directions(self):
  with patch.object(o,'BASE',self.base),self.assertRaises(o.Refused):probe.root_for(ID)
  identifier='223456789';(self.base/'bridge-probes'/('p'+identifier)).mkdir(parents=True,mode=0o700)
  with patch.object(o,'BASE',self.base),self.assertRaises(o.Refused):o.run_root(identifier)
 def test_E3_workflow_changes_only_phase_lists(self):
  repo=Path(o.__file__).parents[2];old=subprocess.check_output(['git','-C',str(repo),'show','30fe1ac:.github/workflows/nightly-refmachine.yml'],text=True)
  expected=old.replace('auth_status, launch, collect]','auth_status, auth_reason, bridge_probe_prepare, bridge_probe, launch, collect]').replace('auth_status|launch|collect)','auth_status|auth_reason|bridge_probe_prepare|bridge_probe|launch|collect)')
  self.assertEqual((repo/'.github/workflows/nightly-refmachine.yml').read_text(),expected)

if __name__=='__main__':unittest.main(verbosity=2)
