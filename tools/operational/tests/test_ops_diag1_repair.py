"""TEST ONLY Class F counterexamples: injected processes/API, no live auth/OS."""
from contextlib import redirect_stdout, redirect_stderr
import io, json, os, subprocess, tempfile, unittest
from pathlib import Path
from unittest.mock import Mock, patch
from test_ops_diag1 import o, a, b, ID, SENTINEL
import g3_bridge_probe as probe

class FirstFailureCounterexamples(unittest.TestCase):
 def setUp(self):
  temp=tempfile.TemporaryDirectory(prefix='TEST_ONLY_first_failure_'); self.addCleanup(temp.cleanup)
  self.base=Path(temp.name); self.root=self.base/('q'+ID); self.root.mkdir(mode=0o700)
 def state(self, **kw):
  value=dict(status='starting', realm=str(self.base/'realm'), ops_sha='a'*40, auth_lifecycle='none', login_complete=False, model_verified=False, native_stopped=False, normal_before={'test_only':True})
  value.update(kw); o.write(self.root/'auth-state.json',value)
  self.assertNotIn('reason',value)
 def test_F1_supervisor_postflow_then_exit_failure(self):
  self.state(); o.write(self.root/'auth-prepare.json',{'qualification_id':ID,'flow_id':'a'*32}); o.write(self.root/'auth-transport.json',{})
  core=Mock(); core.__enter__=Mock(return_value=core); core.__exit__=Mock(side_effect=a.CleanupFailed(['core_stop']))
  transport=Mock(); transport.post.side_effect=b.BridgeRefused('BLOCKED_RECEIVER_REFUSED')
  def flow(core,transport,receipt,update):
   update(auth_lifecycle='completed',login_complete=True); return {'test_only':True}
  def final_cleanup(root,host):
   value=o.read(root/'auth-state.json'); value.update(cleanup_errors=value.get('resource_errors',[])); o.write(root/'auth-state.json',value)
  host=Mock(); host.normal.return_value={'test_only':True}
  with patch.object(o,'verify_stage',return_value={'ops_sha':'a'*40}),patch.object(a,'realm_path',return_value=self.base/'realm'),patch.object(a,'realm_guard'),patch.object(a,'NativeCore',return_value=core),patch.object(a,'device_flow',side_effect=flow),patch.object(a,'revoke'),patch.object(b,'Client',return_value=transport),patch.object(a,'cleanup',side_effect=final_cleanup):
   a.supervisor(self.root,host)
  public=a.public_status(self.root)
  self.assertEqual(public['reason'],'BLOCKED_RECEIVER_REFUSED')
  self.assertIn('BLOCKED_CLEANUP_CORE_STOP',public['cleanup_errors'])
  self.assertEqual(public['status'],'needs_human')
 def test_F1_start_then_stop_failure(self):
  self.state(); core=a.NativeCore.__new__(a.NativeCore)
  core.root=self.root; core.argv=['TEST_ONLY']; core.env={}; core.runtime=self.base/'runtime'; core.child=None
  child=Mock(); child.pid=123; child.poll.return_value=1
  with patch.object(a.subprocess,'Popen',return_value=child),patch.object(o,'witness',return_value={'pid':123,'starttime':1}),patch.object(core,'stop',side_effect=a.CleanupFailed(['core_stop'])):
   with self.assertRaises(o.Refused) as caught:core.__enter__()
  state=o.read(self.root/'auth-state.json')
  self.assertEqual(state.get('reason'),'BLOCKED_NATIVE_CORE_START')
  self.assertEqual(caught.exception.args[0],'BLOCKED_NATIVE_CORE_START')
  self.assertIn('core_stop',state.get('resource_errors',[]))
 def test_F2_probe_transport_then_key_failure(self):
  root=self.base/('p'+ID); host=Mock(); host.command.return_value=subprocess.CompletedProcess([],0,'a'*40,'')
  with patch.dict(os.environ,{'GITHUB_SHA':'a'*40}): receipt=probe.prepare(root,ID,host)
  raw=json.dumps({'expires_at_ms':receipt['expires_at_ms'],'client_sha256':receipt['client_sha256']})
  unlink=Path.unlink
  def deny(path,*args,**kw):
   if path==root/'client/client.key':raise PermissionError(SENTINEL)
   return unlink(path,*args,**kw)
  out,err=io.StringIO(),io.StringIO()
  with patch.dict(os.environ,{'GITHUB_SHA':'a'*40}),patch.object(b,'Client',side_effect=b.BridgeRefused('BLOCKED_MTLS_TCP_TIMEOUT')),patch.object(Path,'unlink',deny),redirect_stdout(out),redirect_stderr(err):result=probe.run(root,host,raw)
  state=o.read(root/'probe-state.json')
  self.assertEqual(result['result'],'BLOCKED_MTLS_TCP_TIMEOUT')
  self.assertEqual(result.get('cleanup_errors'),['BLOCKED_CLEANUP_PROBE_KEYS'])
  self.assertEqual(state.get('cleanup_errors'),result['cleanup_errors'])
  self.assertFalse(result['keys_erased']); self.assertTrue((root/'client/client.key').exists())
  self.assertNotIn(SENTINEL,json.dumps(result)+json.dumps(state)+out.getvalue()+err.getvalue())

if __name__=='__main__': unittest.main(verbosity=2)
