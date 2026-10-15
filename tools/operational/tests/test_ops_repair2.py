"""TEST ONLY counterexamples: real helpers, injected command/RPC/clock edges.
No native/provider/desktop evidence or credentials. Loopback TLS is separate.
"""
from contextlib import ExitStack
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
import g3_ops as o
import g3_auth as a
import g3_device_bridge as b
ID='123456789'

class VirtualClock:
    def __init__(self): self.value=0;self.calls=[]
    def now(self): return self.value
    def advance(self,seconds): self.value+=seconds

class ReadinessFixture:
    """Actual NativeCore.ready/revoke, only boundary files and RPC injected."""
    def __init__(self,root,stack,phases=None):
        self.events=[];self.authenticated=True;self.phases=iter(phases or ['draining','stopped','starting','ready'])
        self.core=a.NativeCore.__new__(a.NativeCore)
        self.core.root=root;self.core.realm=root/'TEST_ONLY_REALM';self.core.identifier=ID
        self.core.call=self.rpc
        realresolve=Path.resolve;realbytes=Path.read_bytes;realtext=Path.read_text
        def resolve(path,*args,**kw):
            return o.CODEX if str(path)=='/proc/999999/exe' else realresolve(path,*args,**kw)
        def raw(path,*args,**kw):
            if str(path)=='/proc/999999/environ':
                return ('HOME='+str(self.core.realm/'state/agent/backend/home')+'\0CODEX_HOME='+str(self.core.realm/'state/agent/backend/codex')+'\0').encode()
            if str(path)=='/proc/999999/cmdline': return b'codex\0--strict-config\0cli_auth_credentials_store="keyring"\0'
            return realbytes(path,*args,**kw)
        def text(path,*args,**kw):
            if str(path)=='/proc/999999/cgroup': return '0::/user.slice/user-1000.slice/user@1000.service/app.slice/ditto-g3-auth-q'+ID+'-agent-backend.scope'
            if str(path).startswith('/sys/fs/cgroup/'):
                return {'memory.max':'1073741824','cpu.max':'200000 100000','pids.max':'256','memory.swap.max':'0'}[path.name]
            return realtext(path,*args,**kw)
        stack.enter_context(patch.object(Path,'resolve',resolve));stack.enter_context(patch.object(Path,'read_bytes',raw));stack.enter_context(patch.object(Path,'read_text',text))
        stack.enter_context(patch.object(o,'sha',return_value=o.CODEX_SHA));stack.enter_context(patch.object(a,'realm_guard'))
        stack.enter_context(patch.object(o,'witness',return_value={'pid':999999,'starttime':'TEST_ONLY'}))
        stack.enter_context(patch.object(o.time,'sleep'))
    def rpc(self,method,params=None,**kw):
        self.events.append(method)
        if method=='agent.runtime.ensure': return {'phase':'draining' if self.events.count(method)==1 else 'starting'}
        if method=='agent.runtime.get': return {'phase':next(self.phases),'isolation_verified':True,'backend_pid':999999}
        if method=='agent.providers.logout': self.authenticated=False;return {'completed':True}
        if method=='agent.providers.status': return {'provider':'codex-app-server','available':True,'authenticated':self.authenticated}
        return {}

class Repair2Counterexamples(unittest.TestCase):
    def setUp(self):
        temp=tempfile.TemporaryDirectory(prefix='TEST_ONLY_ops_repair2_');self.addCleanup(temp.cleanup)
        self.root=Path(temp.name)/('q'+ID);self.root.mkdir()
    def test_A_absent_scopes_prepare_and_repeated_cleanup(self):
        host=o.Host(self.root);host.normal=Mock(return_value={'test_only':True})
        events=[]
        def command(argv,**kw):
            events.append(argv)
            if argv[0]=='systemctl':
                if 'stop' in argv and argv[-1].endswith('.scope'): return subprocess.CompletedProcess(argv,1,'','TEST ONLY unit not loaded')
                if 'is-active' in argv: return subprocess.CompletedProcess(argv,4,'unknown\n','')
                if 'show' in argv:
                    text='' if '--value' in argv else 'LoadState=not-found\nActiveState=inactive\nControlGroup=\n'
                    return subprocess.CompletedProcess(argv,1,text,'')
            text='b false' if argv[0]=='busctl' else 'codex-cli 0.160.0' if '--version' in argv else '--listen' if '--help' in argv else ''
            return subprocess.CompletedProcess(argv,0,text,'')
        def enter(core):
            core.child=Mock();core.child.poll.return_value=0
            state=o.read(self.root/'auth-state.json');state.update(test_only=True);o.write(self.root/'auth-state.json',state)
            return core
        def rpc(core,method,*args,**kw): return {'revision':1} if method=='agent.settings.describe' else {}
        receipt=None;failure=None
        with patch.object(o.subprocess,'run',side_effect=command),patch.object(o,'verify_stage',return_value={'ops_sha':'a'*40}),patch.object(o,'RUNTIME',self.root/'runtime'),patch.object(a,'realm_path',return_value=self.root/'TEST_ONLY_REALM'),patch.object(a,'realm_guard'),patch.object(o,'schema',return_value=5),patch.object(o,'sha',return_value=o.CODEX_SHA),patch.object(a.NativeCore,'__enter__',enter),patch.object(a.NativeCore,'call',rpc),patch.object(b,'certificate',return_value={'certificate':'TEST_ONLY_PUBLIC_CERT','sha256':'a'*64}):
            (self.root/'runtime').mkdir()
            try: receipt=a.prepare(self.root,host)
            except o.Refused as error: failure=str(error)
            self.assertIsNotNone(receipt,'first prepare cannot leave never-created scopes: '+str(failure))
            first=a.cleanup(self.root,host);second=a.cleanup(self.root,host)
        self.assertTrue(first['native_stopped']);self.assertEqual(first,second)
        self.assertEqual(first['cleanup_errors'],[])
        self.assertTrue(any('stop' in v and v[-1].endswith('-agent.scope') for v in events))
    def test_B_real_ready_drains_before_logout(self):
        with ExitStack() as stack:
            fixture=ReadinessFixture(self.root,stack)
            try: a.revoke(fixture.core)
            except o.Refused: pass
            self.assertFalse(fixture.authenticated,'draining prevented formal logout')
            fixture.core.call('agent.runtime.stop')
        self.assertEqual(fixture.events.count('agent.runtime.ensure'),2)
        self.assertLess(fixture.events.index('agent.providers.logout'),fixture.events.index('agent.runtime.stop'))
        self.assertEqual(fixture.events[-3:],['agent.providers.logout','agent.providers.status','agent.runtime.stop'])
    def test_C_total_deadline_persists_attempt_all(self):
        clock=VirtualClock();host=o.Host(self.root);host.normal=Mock(side_effect=lambda: clock.advance(10) or {'test_only':True})
        self.root.joinpath('auth-bridge').mkdir()
        o.write(self.root/'auth-state.json',{'status':'blocked','auth_lifecycle':'completed','normal_before':{'test_only':True},'test_only':True})
        class Cutoff(BaseException): pass
        def advance(amount):
            clock.advance(amount)
            if clock.value>=180: raise Cutoff()
        def command(argv,timeout=10,**kw):
            clock.calls.append((argv,timeout))
            if argv[-1].endswith('.timer'): return subprocess.CompletedProcess(argv,0,'','')
            advance(min(10,timeout))
            if 'stop' in argv: return subprocess.CompletedProcess(argv,0,'','')
            if 'is-active' in argv: return subprocess.CompletedProcess(argv,3,'inactive','')
            if '--value' in argv: return subprocess.CompletedProcess(argv,0,'','')
            return subprocess.CompletedProcess(argv,0,'LoadState=loaded\nActiveState=inactive\nControlGroup=\n','')
        def slow_revoke(root,state):
            advance(29);advance(9.9);advance(10)
            raise TimeoutError('TEST ONLY provider status timeout')
        with patch.object(o.time,'monotonic',clock.now),patch.object(o.time,'sleep',clock.advance),patch.object(o.subprocess,'run',side_effect=command),patch.object(a,'revoke_live_core',side_effect=slow_revoke),patch.object(a,'stop_owned_core'):
            try: a.cleanup(self.root,host)
            except Cutoff: pass
        state=o.read(self.root/'auth-state.json')
        self.assertLess(clock.value,180,'cleanup exceeded service cutoff before persistence')
        self.assertTrue(host.normal.called,'normal readback neither attempted nor budget-recorded')
        self.assertEqual(state.get('cleanup_in_progress'),False)
        self.assertTrue(state.get('cleanup_errors'),'failures were not persisted')
        self.assertEqual(state['status'],'needs_human')
        self.assertEqual(set(state.get('cleanup_pending',[])),set())

if __name__=='__main__': unittest.main(verbosity=2)
