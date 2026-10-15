"""TEST ONLY unchanged-code diagnostic counterexamples; no live auth/message."""
from contextlib import redirect_stdout,redirect_stderr
import io,json
from pathlib import Path
import sys,tempfile,unittest
from unittest.mock import Mock,patch
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
import g3_ops as o
import g3_auth as a
import g3_device_bridge as b
from test_ops_repair1 import RealmCore,ID
SENTINEL='SECRET_SENTINEL_TEST_ONLY'
class DiagnosticCounterexamples(unittest.TestCase):
 def setUp(self):
  temp=tempfile.TemporaryDirectory(prefix='TEST_ONLY_diag1_');self.addCleanup(temp.cleanup)
  self.root=Path(temp.name)/('q'+ID);self.root.mkdir()
 def receipt(self):return {'qualification_id':ID,'flow_id':'a'*32,'expires_at_ms':b.now_ms()+180000}
 def test_D1_url_reason_without_connection(self):
  core=RealmCore();call=core.call;transport=Mock();updates=[]
  def rpc(method,*args,**kw):
   value=call(method,*args,**kw)
   if method=='agent.providers.login':value['auth_url']='https://auth.openai.com/OTHER_'+SENTINEL;value['login_id']=SENTINEL
   return value
  core.call=rpc
  with self.assertRaises(o.Refused) as caught:a.device_flow(core,transport,self.receipt(),lambda **v:updates.append(v))
  self.assertEqual(caught.exception.args[0],'BLOCKED_DEVICE_PAYLOAD_URL')
  transport.post.assert_not_called();self.assertNotIn(SENTINEL,json.dumps(updates)+str(caught.exception))
 def test_D1_connect_refused(self):
  client=b.Client.__new__(b.Client);client.config={'host':'127.0.0.1','port':65534,'expires_at_ms':b.now_ms()+10000,'server_sha256':'a'*64};client.context=None
  connection=Mock();connection.connect.side_effect=ConnectionRefusedError(111,SENTINEL)
  with patch.object(b.http.client,'HTTPSConnection',return_value=connection),self.assertRaises(b.BridgeRefused) as caught:client.post('/status',{'status':'blocked'})
  self.assertEqual(caught.exception.args[0],'BLOCKED_MTLS_TCP_REFUSED')
  self.assertNotIn(SENTINEL,str(caught.exception))
 def test_D2_constructor_failure_recorded(self):
  o.write(self.root/'auth-state.json',{'status':'starting','realm':'TEST_ONLY','ops_sha':'a'*40,'login_complete':False,'model_verified':False,'native_stopped':False})
  o.write(self.root/'auth-prepare.json',self.receipt());o.write(self.root/'auth-transport.json',{})
  out,err=io.StringIO(),io.StringIO()
  with patch.object(o,'verify_stage',return_value={'ops_sha':'a'*40}),patch.object(b,'Client',side_effect=b.BridgeRefused('BLOCKED_TRANSPORT_EXPIRED')),patch.object(a,'cleanup'),redirect_stdout(out),redirect_stderr(err):
   try:a.supervisor(self.root,Mock())
   except b.BridgeRefused:pass
  state=o.read(self.root/'auth-state.json')
  self.assertEqual(state.get('reason'),'BLOCKED_TRANSPORT_EXPIRED')
  self.assertEqual(state.get('last_marker'),'supervisor_started')
  self.assertNotIn(SENTINEL,json.dumps(state)+out.getvalue()+err.getvalue())
 def test_D3_unknown_reason_refused(self):
  o.write(self.root/'auth-state.json',{'status':'blocked','reason':SENTINEL,'last_marker':SENTINEL,'auth_lifecycle':SENTINEL,'cleanup_errors':[SENTINEL],'login_complete':False,'model_verified':False,'native_stopped':True})
  result=a.public_status(self.root)
  self.assertEqual(result.get('reason'),'BLOCKED_UNLISTED_REASON')
  self.assertNotIn(SENTINEL,json.dumps(result))
if __name__=='__main__':unittest.main(verbosity=2)
