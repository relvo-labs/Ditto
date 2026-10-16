"""TEST ONLY fixed endpoint amendment; no Tailscale/LAN socket or Home call."""
from contextlib import redirect_stdout
import io,json,shutil,socket,ssl,tempfile,threading,unittest
from pathlib import Path
from unittest.mock import Mock,patch
import test_device_bridge as tls
b=tls.b
PARENT='100.88.143.32'
OLD='192.168.1.102'
ID,FLOW=tls.IDENTIFIER,tls.FLOW
class FixedParentEndpoint(unittest.TestCase):
 @classmethod
 def setUpClass(cls):
  cls.temp=tempfile.TemporaryDirectory(prefix='TEST_ONLY_endpoint_certs_');cls.base=Path(cls.temp.name)
  cls.certs={}
  for role,ip in [('server','127.0.0.1'),('client','10.0.1.234')]:
   directory=cls.base/role;directory.mkdir(mode=0o700)
   cls.certs[role]=b.certificate(directory,role,ip)
 @classmethod
 def tearDownClass(cls):cls.temp.cleanup()
 def setUp(self):
  temp=tempfile.TemporaryDirectory(prefix='TEST_ONLY_endpoint_');self.addCleanup(temp.cleanup);self.root=Path(temp.name)
 def config(self,host):
  return dict(qualification_id=ID,flow_id=FLOW,host=host,port=55000,server_certificate=self.certs['server']['certificate'],server_sha256=self.certs['server']['sha256'],client_sha256=self.certs['client']['sha256'],expires_at_ms=b.now_ms()+120000)
 def test_authorized_parent_accepted(self):
  refusal=None
  try:b.validate_transport(self.config(PARENT),ID,FLOW)
  except b.BridgeRefused as error:refusal=error.args[0]
  self.assertIsNone(refusal)
 def test_stale_lan_refused(self):
  with self.assertRaises(b.BridgeRefused):b.validate_transport(self.config(OLD),ID,FLOW)
 def test_arbitrary_hosts_refused(self):
  for host in ['example.invalid','100.72.193.4','100.88.143.33','0.0.0.0','127.0.0.1',PARENT+':55000',PARENT+'.']:
   with self.subTest(host=host),self.assertRaises(b.BridgeRefused):b.validate_transport(self.config(host),ID,FLOW)
  with self.assertRaises(b.BridgeRefused):b.validate_transport(self.config(PARENT),ID,FLOW,loopback=True)
 def test_server_certificate_san(self):
  directory=self.root/'new';directory.mkdir(mode=0o700);refusal=None
  try:cert=b.certificate(directory,'server',PARENT)
  except b.BridgeRefused as error:refusal=error.args[0]
  self.assertIsNone(refusal)
  info=ssl._ssl._test_decode_cert(str(directory/'server.pem'))
  self.assertEqual(info['subjectAltName'],(('IP Address',PARENT),))
  self.assertEqual(cert['sha256'],b.fingerprint(cert['certificate']))
 def test_stale_certificate_address_refused(self):
  directory=self.root/'old';directory.mkdir(mode=0o700)
  with self.assertRaises(b.BridgeRefused):b.certificate(directory,'server',OLD)
  self.assertEqual(list(directory.iterdir()),[])
 def prepared(self,probe):
  directory=self.root/('probe' if probe else 'auth')
  receipt=dict(qualification_id=ID,flow_id=FLOW,source='17f5d76dc043d7d8117f1e99458a9a0c9255354b',ops_sha='a'*40,evidence_class='mtls-probe-prepare' if probe else 'native-core-auth-prepare',client_certificate=self.certs['client']['certificate'],client_sha256=self.certs['client']['sha256'],expires_at_ms=b.now_ms()+120000)
  # Only abandoned-prepare disposal spawn is injected; real cert/config code.
  original_popen=b.subprocess.Popen
  def spawn(argv,*args,**kwargs):
   if len(argv)>2 and argv[2]=='expire':return Mock(pid=999999)
   return original_popen(argv,*args,**kwargs)  # OpenSSL runs for real
  with patch.object(b.subprocess,'Popen',side_effect=spawn),patch.object(b,'process_start',return_value=None):config=b.prepare_receiver(receipt,directory,probe=probe)
  self.addCleanup(b.erase_keys,directory,'server')
  return directory,config
 def test_prepare_advertises_and_certifies_parent(self):
  for probe in [False,True]:
   with self.subTest(probe=probe):
    directory,config=self.prepared(probe)
    self.assertEqual(config['host'],PARENT)
    self.assertEqual(ssl._ssl._test_decode_cert(str(directory/'server.pem'))['subjectAltName'],(('IP Address',PARENT),))
    self.assertTrue(49152<=config['port']<=65535);self.assertNotIn('PRIVATE KEY',json.dumps(config))
 def test_serve_binds_parent_and_cleans(self):
  for probe in [False,True]:
   with self.subTest(probe=probe):
    directory,config=self.prepared(probe);addresses=[]
    class TestOnlySocketBoundary:
     def __init__(inner,address,context,state):
      addresses.append(address);self.assertEqual(context.verify_mode,ssl.CERT_REQUIRED);self.assertGreaterEqual(context.minimum_version,ssl.TLSVersion.TLSv1_2);state.done=True
     def server_close(inner):pass
    with patch.object(b,'QuietServer',TestOnlySocketBoundary),patch.object(b,'send_home') as sender,redirect_stdout(io.StringIO()):result=b.serve_receiver(directory,probe=probe)
    self.assertEqual(addresses,[(PARENT,config['port'])]);sender.assert_not_called()
    for name in ['server.key','server.pem','client.pem','transport.json','disposal.json']:self.assertFalse((directory/name).exists())
    if probe:self.assertEqual(result,{'result':'PROBE_OK','keys_erased':True})
 def test_client_san_identity_over_real_loopback(self):
  self.assertEqual(ssl._ssl._test_decode_cert(str(self.base/'client/client.pem'))['subjectAltName'],(('IP Address','10.0.1.234'),))
  state=b.ProbeReceiverState(ID,FLOW,self.certs['client']['sha256'],b.now_ms()+120000)
  context=b.server_context(self.base/'server',self.certs['client']['certificate'])
  for port in range(52000,52100):
   try:server=b.QuietServer(('127.0.0.1',port),context,state);break
   except OSError:pass
  else:self.fail('TEST ONLY loopback ports unavailable')
  thread=threading.Thread(target=server.handle_request,daemon=True);thread.start()
  try:
   config={**self.config('127.0.0.1'),'port':port,'expires_at_ms':state.deadline}
   client=b.Client(self.base/'client',config,ID,FLOW,loopback=True,probe=True)
   self.assertTrue(client.context.check_hostname);self.assertEqual(client.context.verify_mode,ssl.CERT_REQUIRED)
   self.assertEqual(client.post('/probe',dict(qualification_id=ID,flow_id=FLOW,probe='reachability-v1')),{'status':'PROBE_OK'})
  finally:thread.join(timeout=5);server.server_close()
  self.assertFalse(thread.is_alive());self.assertTrue(state.done)
if __name__=='__main__':unittest.main(verbosity=2)
