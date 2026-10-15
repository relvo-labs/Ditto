"""TEST ONLY pinned-Core envelope; real loopback TLS, in-memory sender only."""
import json, tempfile, unittest
from pathlib import Path
from unittest.mock import Mock, patch
import test_device_bridge as tls
from test_ops_repair1 import o,a,b,RealmCore,ID
META={'observed_seq':987654321012345,'profile_revision':None,'readback_verified':False,'handled_us':1}
class EnvelopeCore(RealmCore):
 def call(self,*args,**kw):
  value=super().call(*args,**kw)
  return {**value,'_meta':dict(META)} if type(value) is dict else value

class EnvelopeCounterexamples(unittest.TestCase):
 setUpClass=tls.LoopbackBridge.__dict__['setUpClass']
 tearDownClass=tls.LoopbackBridge.__dict__['tearDownClass']
 setUp=tls.LoopbackBridge.setUp
 tearDown=tls.LoopbackBridge.tearDown
 run_server=tls.LoopbackBridge.run_server
 def receipt(self):return {'qualification_id':ID,'flow_id':tls.FLOW,'expires_at_ms':self.state.deadline}
 def test_G1_real_flow_loopback(self):
  updates=[];failure=None
  with patch.object(a,'minimal_probe',return_value={'test_only':True}):
   try:a.device_flow(EnvelopeCore(),self.client,self.receipt(),lambda **v:updates.append(v))
   except o.Refused as error:failure=error.args[0]
  self.assertIsNone(failure)
  self.assertEqual(len(self.messages),2)
  self.assertIn('payload_validated',[v.get('last_marker') for v in updates])
  self.assertNotIn(str(META['observed_seq']),json.dumps(updates)+json.dumps(self.messages))
  self.assertNotIn('"_meta"',json.dumps(updates)+json.dumps(self.messages))
 def test_G1_supervisor_loopback(self):
  with tempfile.TemporaryDirectory(prefix='TEST_ONLY_meta_supervisor_') as temp:
   root=Path(temp)/('q'+ID);root.mkdir();realm=root/'realm'
   o.write(root/'auth-state.json',dict(test_only=True,status='starting',realm=str(realm),ops_sha='a'*40,auth_lifecycle='none',login_complete=False,model_verified=False,native_stopped=False,normal_before={'test_only':True}))
   o.write(root/'auth-prepare.json',self.receipt());o.write(root/'auth-transport.json',{})
   core=EnvelopeCore();cm=Mock();cm.__enter__=Mock(return_value=core);cm.__exit__=Mock(return_value=False)
   host=Mock();host.normal.return_value={'test_only':True}
   with patch.object(o,'verify_stage',return_value={'ops_sha':'a'*40}),patch.object(a,'realm_path',return_value=realm),patch.object(a,'realm_guard'),patch.object(a,'NativeCore',return_value=cm),patch.object(b,'Client',return_value=self.client),patch.object(a,'minimal_probe',return_value={'test_only':True}),patch.object(a,'cleanup'),patch.object(o,'sha',return_value='a'*64):a.supervisor(root,host)
   state=o.read(root/'auth-state.json');public=a.public_status(root)
   self.assertEqual(state['status'],'verified');self.assertEqual(len(self.messages),3)
   self.assertTrue(state['test_only'])
   for text in (json.dumps(state),json.dumps(public),json.dumps(self.messages)):
    self.assertNotIn('"_meta"',text);self.assertNotIn(str(META['observed_seq']),text)
 def test_G1_unknown_field(self):
  core=EnvelopeCore();call=core.call
  def rpc(method,*args,**kw):
   value=call(method,*args,**kw)
   if method=='agent.providers.login':value['unknown']='TEST_ONLY_EXTRA'
   return value
  core.call=rpc
  with self.assertRaisesRegex(o.Refused,'BLOCKED_DEVICE_LOGIN_METHOD'):a.device_flow(core,self.client,self.receipt(),lambda **v:None)
  self.assertEqual(self.messages,[])
 def test_G1_bad_meta(self):
  for bad in (None,[],1,'TEST_ONLY_BAD'):
   core=EnvelopeCore();call=core.call
   def rpc(method,*args,**kw):
    value=call(method,*args,**kw)
    if method=='agent.providers.login':value['_meta']=bad
    return value
   core.call=rpc
   with self.subTest(value=bad),self.assertRaisesRegex(o.Refused,'BLOCKED_DEVICE_LOGIN_METHOD'):a.device_flow(core,self.client,self.receipt(),lambda **v:None)
  self.assertEqual(self.messages,[])
if __name__=='__main__':unittest.main(verbosity=2)
