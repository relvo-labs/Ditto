"""TEST ONLY sibling transitions using real failure handlers and temp files."""
from contextlib import redirect_stdout, redirect_stderr
import io, json, os, subprocess, unittest
from pathlib import Path
from unittest.mock import Mock, patch
import test_ops_diag1_repair as counterexamples
from test_ops_diag1 import o, a, b, ID, SENTINEL
import g3_bridge_probe as probe
import g3_diagnostics as diag

class FirstFailureSurfaces(unittest.TestCase):
 setUp = counterexamples.FirstFailureCounterexamples.setUp
 state = counterexamples.FirstFailureCounterexamples.state
 def test_real_context_exit_persists_before_stop_and_propagates_first(self):
  self.state(); core=a.NativeCore.__new__(a.NativeCore); core.root=self.root
  def stop():
   self.assertEqual(o.read(self.root/'auth-state.json')['reason'],'BLOCKED_RECEIVER_REFUSED')
   raise a.CleanupFailed(['core_stop'])
  core.stop=stop
  failure=b.BridgeRefused('BLOCKED_RECEIVER_REFUSED')
  self.assertFalse(core.__exit__(type(failure),failure,None))
  state=o.read(self.root/'auth-state.json')
  self.assertEqual(state['reason'],'BLOCKED_RECEIVER_REFUSED'); self.assertEqual(state['resource_errors'],['core_stop'])
  self.assertEqual(state['status'],'needs_human')
 def test_successful_context_cleanup_failure_is_first_failure(self):
  self.state(); core=a.NativeCore.__new__(a.NativeCore); core.root=self.root
  core.stop=Mock(side_effect=a.CleanupFailed(['runtime_stop']))
  with self.assertRaises(a.CleanupFailed):core.__exit__(None,None,None)
  self.assertEqual(o.read(self.root/'auth-state.json')['reason'],'BLOCKED_AUTH_CLEANUP')
 def test_popen_failure_records_constant_before_cleanup(self):
  self.state(); core=a.NativeCore.__new__(a.NativeCore); core.root=self.root; core.argv=['TEST_ONLY']; core.env={}; core.child=None
  def stop():
   self.assertEqual(o.read(self.root/'auth-state.json')['reason'],'BLOCKED_NATIVE_CORE_START')
   raise a.CleanupFailed(['runtime_stop'])
  core.stop=stop
  with patch.object(a.subprocess,'Popen',side_effect=OSError(SENTINEL)),self.assertRaises(o.Refused) as caught:core.__enter__()
  self.assertNotIn(SENTINEL,str(caught.exception)+(self.root/'auth-state.json').read_text())
  self.assertEqual(caught.exception.args[0],'BLOCKED_NATIVE_CORE_START')
 def test_cleanup_merges_core_reason_without_interrupted_overwrite(self):
  self.state(auth_lifecycle='none'); host=Mock(); host.normal.return_value={'test_only':True}
  def scopes(*args):
   a.record_failure(self.root,o.Refused('BLOCKED_NATIVE_CORE_START'),'BLOCKED_AUTH_CLEANUP')
   a.record_failure(self.root,a.CleanupFailed(['core_stop']),'BLOCKED_AUTH_CLEANUP')
   return []
  with patch.object(b,'erase_keys'),patch.object(a,'stop_scopes',side_effect=scopes),patch.object(a,'scope_readbacks',return_value=[]),patch.object(a,'stop_owned_core'):
   result=a.cleanup(self.root,host)
  self.assertEqual(result['reason'],'BLOCKED_NATIVE_CORE_START');self.assertEqual(result['status'],'needs_human')
  self.assertIn('BLOCKED_CLEANUP_CORE_STOP',a.public_status(self.root)['cleanup_errors'])
 def test_auth_prepare_wrapper_preserves_core_reason_and_key_failure(self):
  host=Mock(); host.env={}; host.normal.return_value={'test_only':True}
  host.command.side_effect=[subprocess.CompletedProcess([],0,'b false',''),subprocess.CompletedProcess([],0,'codex-cli 0.160.0',''),subprocess.CompletedProcess([],0,'--listen','')]
  realm=self.base/'realm'; realm.parent.mkdir(exist_ok=True)
  core=Mock()
  def enter():
   a.record_failure(self.root,o.Refused('BLOCKED_NATIVE_CORE_START'),'BLOCKED_AUTH_PREPARE')
   raise o.Refused('BLOCKED_NATIVE_CORE_START')
  core.__enter__=Mock(side_effect=enter);core.__exit__=Mock()
  with patch.object(o,'verify_stage',return_value={'ops_sha':'a'*40}),patch.object(o,'sha',return_value=o.CODEX_SHA),patch.object(a,'realm_path',return_value=realm),patch.object(a,'NativeCore',return_value=core),patch.object(b,'erase_keys',side_effect=PermissionError(SENTINEL)),self.assertRaises(o.Refused) as caught:a.prepare(self.root,host)
  state=o.read(self.root/'auth-state.json')
  self.assertEqual(caught.exception.args[0],'BLOCKED_NATIVE_CORE_START');self.assertEqual(state['reason'],'BLOCKED_NATIVE_CORE_START')
  self.assertEqual(state['resource_errors'],['bridge_keys']);self.assertEqual(state['status'],'needs_human')
  self.assertNotIn(SENTINEL,json.dumps(state)+str(caught.exception))
 def probe_prepare(self):
  root=self.base/('p'+ID);host=Mock();host.command.return_value=subprocess.CompletedProcess([],0,'a'*40,'')
  with patch.dict(os.environ,{'GITHUB_SHA':'a'*40}):receipt=probe.prepare(root,ID,host)
  return root,host,receipt
 def test_probe_success_transport_and_failed_cleanup_are_separate(self):
  root,host,receipt=self.probe_prepare();raw=json.dumps({k:receipt[k] for k in ('expires_at_ms','client_sha256')})
  with patch.dict(os.environ,{'GITHUB_SHA':'a'*40}),patch.object(b,'Client'),patch.object(probe,'cleanup',side_effect=PermissionError(SENTINEL)):
   result=probe.run(root,host,raw)
  self.assertEqual(result['result'],'PROBE_OK');self.assertFalse(result['keys_erased'])
  self.assertEqual(result['cleanup_errors'],['BLOCKED_CLEANUP_PROBE_KEYS'])
 def test_probe_prepare_failure_is_saved_before_failed_erase(self):
  root=self.base/('p'+ID);host=Mock()
  host.command.side_effect=[subprocess.CompletedProcess([],0,'a'*40,''),o.Refused('BLOCKED_PROBE_BINDING')]
  def fail(root):
   self.assertEqual(o.read(root/'probe-state.json')['result'],'BLOCKED_PROBE_BINDING')
   raise PermissionError(SENTINEL)
  with patch.dict(os.environ,{'GITHUB_SHA':'a'*40}),patch.object(probe,'cleanup',side_effect=fail),self.assertRaises(o.Refused) as caught:probe.prepare(root,ID,host)
  state=o.read(root/'probe-state.json')
  self.assertEqual(caught.exception.args[0],'BLOCKED_PROBE_BINDING');self.assertFalse(state['keys_erased'])
  self.assertEqual(state['cleanup_errors'],['BLOCKED_CLEANUP_PROBE_KEYS']);self.assertNotIn(SENTINEL,json.dumps(state)+str(caught.exception))
 def test_closed_catalog_matches_runtime(self):
  value=json.loads((o.HERE/'diagnostic-codes.json').read_text())
  self.assertEqual(value,{'reasons':sorted(diag.REASONS),'markers':sorted(diag.MARKERS),'auth_lifecycles':sorted(diag.LIFECYCLES),'cleanup_codes':sorted(diag.CLEANUP_CODES)})

if __name__=='__main__':unittest.main(verbosity=2)
