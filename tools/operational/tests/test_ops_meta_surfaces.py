"""TEST ONLY real envelope consumers with injected command/socket boundaries."""
import json, subprocess, tempfile, unittest
from pathlib import Path
from unittest.mock import Mock, MagicMock, patch
import test_ops_meta_repair as meta
from test_ops_repair1 import o,a,RealmCore
class EnvelopeSurfaces(unittest.TestCase):
 def setUp(self):
  temp=tempfile.TemporaryDirectory(prefix='TEST_ONLY_meta_edges_');self.addCleanup(temp.cleanup);self.root=Path(temp.name)
 def test_shared_helper_strict_only_reserved_key(self):
  original={'known':1,'unknown':2,'_meta':dict(meta.META)}
  self.assertEqual(o.core_result(original),{'known':1,'unknown':2});self.assertIn('_meta',original)
  self.assertEqual(o.core_result({'known':1}),{'known':1})
  for bad in (None,1,[],True,'TEST_ONLY'):
   with self.subTest(bad=bad),self.assertRaisesRegex(o.Refused,'BLOCKED_NATIVE_MANAGED_API'):o.core_result({'_meta':bad})
 def test_native_socket_boundary(self):
  core=a.NativeCore.__new__(a.NativeCore);core.runtime=self.root
  sock=MagicMock();sock.__enter__.return_value=sock
  sock.recv.return_value=json.dumps({'result':{'completed':True,'_meta':meta.META}}).encode()+b'\n'
  with patch.object(a.socket,'socket',return_value=sock):value=core.call('agent.providers.logout')
  self.assertEqual(value,{'completed':True});self.assertNotIn('_meta',json.dumps(sock.sendall.call_args.args[0].decode()))
 def test_native_bad_login_meta_preserves_method_code(self):
  core=a.NativeCore.__new__(a.NativeCore);core.runtime=self.root;sock=MagicMock();sock.__enter__.return_value=sock
  sock.recv.return_value=b'{"result":{"_meta":null}}\n'
  with patch.object(a.socket,'socket',return_value=sock),self.assertRaisesRegex(o.Refused,'BLOCKED_DEVICE_LOGIN_METHOD'):core.call('agent.providers.login')
 def test_host_relay_boundary(self):
  host=o.Host(self.root)
  reply=subprocess.CompletedProcess([],0,json.dumps({'result':{'profile':{'profile_id':'TEST_ONLY'},'_meta':meta.META}}),'')
  with patch.object(o,'normal_helper',return_value=self.root/'TEST_ONLY_HELPER'),patch.object(host,'command',return_value=reply):value=host.relay('desktop.profiles.get')
  self.assertEqual(value,{'profile':{'profile_id':'TEST_ONLY'}})
 def test_runtime_envelope(self):
  calls=[]
  def rpc(method):calls.append(method);return {'phase':'ready','_meta':dict(meta.META)}
  self.assertEqual(o.wait_ready(rpc)['phase'],'ready');self.assertEqual(calls,['agent.runtime.ensure','agent.runtime.get'])
 def test_settings_probe_envelope(self):
  calls=[]
  def rpc(method,params=None,**kwargs):
   calls.append((method,params))
   if params and 'settings' in params:self.assertNotIn('_meta',params['settings'])
   values={
    'agent.settings.describe':{'revision':1,'enabled':False},
    'agent.settings.patch':{'revision':1,'model':a.MODEL,'reasoning_effort':a.EFFORT},
    'desktop.profiles.get':{'revision':{'document_sha256':'a'*64}},
    'agent.sessions.create':{'session_id':'TEST_ONLY'},
    'agent.turns.submit':{'turn_id':'TEST_ONLY'},
    'agent.turns.get':{'state':'succeeded','tool_calls':0},
    'agent.turns.trace':{'tools':[]},
    'agent.sessions.read':{'events':[{'type':'model/selection','data':{'model':a.MODEL,'provider':'codex-app-server','settings_revision':1}}]},
   }
   return {**values[method],'_meta':dict(meta.META)}
  core=Mock();core.call.side_effect=rpc
  value=a.minimal_probe(core)
  self.assertEqual(value['request_count'],1);self.assertNotIn('_meta',json.dumps(value));self.assertNotIn(str(meta.META['observed_seq']),json.dumps(value))
  self.assertEqual(sum(m=='agent.turns.submit' for m,p in calls),1)
 def test_physical_snapshot_envelope(self):
  o.write(self.root/'state.json',{'mode':'full'});(self.root/'evidence/full').mkdir(parents=True)
  host=Mock()
  def rpc(method,params=None):
   value={'agent.runtime.ensure':{'phase':'starting'},'agent.runtime.get':{'phase':'ready'},'desktop.profiles.get':{'profile':{'profile_id':'TEST_ONLY'}},'agent.settings.describe':{'revision':1},'desktop.permissions.list':{'grants':[]},'agent.providers.status':{'authenticated':True},'agent.runtime.stop':{}}[method]
   return {**value,'_meta':dict(meta.META)}
  host.private_relay.side_effect=rpc;o.enter(self.root,host)
  saved=(self.root/'evidence/full/private-before.json').read_text()
  self.assertNotIn('_meta',saved);self.assertNotIn(str(meta.META['observed_seq']),saved)
 def test_fake_envelope_contract(self):
  from test_g3_auth import TestOnlyCore
  for core in (RealmCore(),TestOnlyCore()):
   self.check_fake(core)
 def check_fake(self,core):
  for method in ('agent.providers.status','agent.providers.login','agent.providers.logout','agent.providers.cancel_login','agent.runtime.stop'):
   value=core.call(method)
   self.assertEqual(value['_meta'],{'observed_seq':1,'profile_revision':None,'readback_verified':False,'handled_us':1})
  self.assertFalse(core.call('agent.providers.status')['authenticated'])
if __name__=='__main__':unittest.main(verbosity=2)
