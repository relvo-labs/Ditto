"""TEST ONLY transition tables; injected local host/API failures, no live OS."""
from contextlib import ExitStack
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import g3_ops as o
import g3_auth as a
import g3_device_bridge as b
from test_ops_repair1 import RealmCore, RecoveryHost, ID

class Surfaces(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix='TEST_ONLY_surfaces_')
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)/('q'+ID)
        self.root.mkdir()
        self.receipt = {'qualification_id': ID, 'flow_id': 'a'*32, 'expires_at_ms': b.now_ms()+180000}
    def flow_failure(self, core, transport=None, probe=None):
        updates=[]
        with patch.object(a, 'minimal_probe', side_effect=probe or o.Refused('BLOCKED_TEST_ONLY_PROBE')):
            with self.assertRaises(o.Refused) as failure:
                a.device_flow(core, transport or Mock(), self.receipt, lambda **v: updates.append(v))
        self.assertNotIn('TEST-1234', str(failure.exception)+json.dumps(updates))
        return updates
    def test_transport_failure_after_login_attempt_revokes(self):
        core=RealmCore()
        transport=Mock();transport.post.side_effect=RuntimeError('TEST-1234')
        self.flow_failure(core,transport)
        self.assertFalse(core.authenticated)
        self.assertEqual(core.calls[-1],'agent.runtime.stop')
    def test_login_complete_status_forward_failure_revokes(self):
        core=RealmCore(); transport=Mock()
        transport.post.side_effect=lambda path,value: (_ for _ in ()).throw(RuntimeError('TEST-1234')) if path=='/status' else None
        updates=self.flow_failure(core,transport)
        self.assertTrue(any(v.get('login_complete') for v in updates))
        self.assertFalse(core.authenticated)
    def test_model_mismatch_after_completed_login_revokes(self):
        core=RealmCore(); call=core.call
        def rpc(method,*args,**kw):
            value=call(method,*args,**kw)
            if method=='agent.providers.status': value['models']=[]
            return value
        core.call=rpc
        self.flow_failure(core)
        self.assertFalse(core.authenticated)
    def test_ambiguous_login_response_revokes_possible_auth(self):
        core=RealmCore(); call=core.call
        def rpc(method,*args,**kw):
            value=call(method,*args,**kw)
            return 'TEST-1234' if method=='agent.providers.login' else value
        core.call=rpc
        self.flow_failure(core)
        self.assertFalse(core.authenticated)
    def test_cancel_false_is_followed_by_logout_and_status(self):
        core=RealmCore(); self.flow_failure(core)
        sequence=['agent.providers.cancel_login','agent.providers.logout','agent.providers.status','agent.runtime.stop']
        self.assertEqual(core.calls[-4:],sequence)
    def test_logout_false_preserves_original_failure_and_needs_human(self):
        core=RealmCore(); call=core.call
        def rpc(method,*args,**kw):
            if method=='agent.providers.logout': core.calls.append(method);return {'completed':False}
            return call(method,*args,**kw)
        core.call=rpc;updates=self.flow_failure(core)
        self.assertTrue(core.authenticated)
        self.assertTrue(any(v.get('status')=='needs_human' for v in updates))
        self.assertTrue(any(v.get('reason')=='BLOCKED_TEST_ONLY_PROBE' for v in updates))
    def test_status_still_authenticated_after_logout_needs_human(self):
        core=RealmCore();call=core.call
        def rpc(method,*args,**kw):
            if method=='agent.providers.logout': core.calls.append(method);return {'completed':True}
            return call(method,*args,**kw)
        core.call=rpc
        updates=self.flow_failure(core)
        self.assertTrue(any(v.get('revocation_error') for v in updates))
    def test_unknown_auth_method_readback_needs_human(self):
        core=RealmCore();call=core.call
        def rpc(method,*args,**kw):
            value=call(method,*args,**kw)
            if method=='agent.providers.status' and len(core.calls)>1: value['provider']='api-key'
            return value
        core.call=rpc
        updates=self.flow_failure(core)
        self.assertFalse(core.authenticated)
        self.assertTrue(any(v.get('status')=='needs_human' for v in updates))
    def test_expiry_pending_flow_cancel_logout_before_stop(self):
        core=RealmCore(); call=core.call
        def rpc(method,*args,**kw):
            value=call(method,*args,**kw)
            if method=='agent.providers.login': value['expires_at_ms']=b.now_ms()-1
            return value
        core.call=rpc;self.flow_failure(core)
        self.assertFalse(core.authenticated)
        self.assertEqual(core.calls[-1],'agent.runtime.stop')
    def test_signal_during_provider_poll_revokes(self):
        core=RealmCore();call=core.call
        def rpc(method,*args,**kw):
            value=call(method,*args,**kw)
            if method=='agent.providers.status' and core.authenticated and 'agent.providers.logout' not in core.calls:
                raise o.Refused('BLOCKED_AUTH_SIGNAL')
            return value
        core.call=rpc;self.flow_failure(core)
        self.assertFalse(core.authenticated)
    def test_final_verified_forward_failure_revokes_before_core_stop(self):
        self.root.joinpath('auth-bridge').mkdir()
        state={'status':'starting','realm':str(self.root/'realm'),'ops_sha':'a'*40,'normal_before':{'test_only':True}}
        o.write(self.root/'auth-state.json',state);o.write(self.root/'auth-prepare.json',self.receipt);o.write(self.root/'auth-transport.json',{})
        core=RealmCore();cm=Mock();cm.__enter__=Mock(return_value=core);cm.__exit__=Mock(side_effect=lambda *args: core.calls.append('CORE_EXIT'))
        transport=Mock()
        transport.post.side_effect=lambda path,value: (_ for _ in ()).throw(RuntimeError('TEST-1234')) if value.get('status')=='verified' else None
        host=Mock();host.normal.return_value={'test_only':True}
        with patch.object(o,'verify_stage',return_value={'ops_sha':'a'*40}),patch.object(a,'realm_path',return_value=self.root/'realm'),patch.object(a,'realm_guard'),patch.object(a,'NativeCore',return_value=cm),patch.object(b,'Client',return_value=transport),patch.object(a,'minimal_probe',return_value={'test_only':True}),patch.object(a,'cleanup'):
            a.supervisor(self.root,host)
        result=o.read(self.root/'auth-state.json')
        self.assertFalse(core.authenticated)
        self.assertLess(core.calls.index('agent.providers.logout'),core.calls.index('CORE_EXIT'))
        self.assertEqual(result['status'],'blocked');self.assertTrue(result['model_verified'])
        self.assertNotIn('TEST-1234',json.dumps(result))
    def scopes(self, failure):
        events=[]
        def command(argv, **kw):
            action, unit = argv[2], argv[3]
            events.append((action, unit))
            if action=='stop' and unit.endswith('-agent.scope') and failure!='residual':
                raise subprocess.TimeoutExpired('TEST ONLY',1) if failure=='timeout' else o.Refused('TEST ONLY')
            if action=='stop': return subprocess.CompletedProcess(argv,0,'','')
            active = 'active' if failure=='residual' and unit.endswith('-agent.scope') else 'inactive'
            return subprocess.CompletedProcess(argv,0,'LoadState=loaded\nActiveState='+active+'\nControlGroup=\n','')
        host=Mock();host.command.side_effect=command
        with patch.object(o,'Host',return_value=host): errors=a.stop_scopes(self.root,ID)
        self.assertEqual([e[1] for e in events if e[0]=='stop'],a.owned_units(ID))
        self.assertEqual([e[1] for e in events if e[0]=='show'],a.owned_units(ID))
        self.assertTrue(errors)
    def test_first_scope_raises_later_scopes_and_readbacks_attempted(self): self.scopes('raises')
    def test_first_scope_timeout_later_scopes_and_readbacks_attempted(self): self.scopes('timeout')
    def test_first_scope_residual_later_scopes_and_readbacks_attempted(self): self.scopes('residual')
    def test_native_stop_scope_failure_still_terminates_core_and_reads_back(self):
        core=a.NativeCore.__new__(a.NativeCore);core.root=self.root;core.identifier=ID;core.runtime=self.root;core.call=Mock()
        child=Mock();child.poll.side_effect=[None,0];core.child=child
        with patch.object(a,'stop_scopes',side_effect=o.Refused('TEST ONLY')),patch.object(a,'scope_readbacks',return_value=['TEST_ONLY_final_failure']) as readback:
            with self.assertRaises(a.CleanupFailed) as result: core.stop()
        child.terminate.assert_called_once();child.wait.assert_called_once();readback.assert_called_once()
        self.assertEqual(result.exception.errors,['scope_stop','TEST_ONLY_final_failure'])
    def test_cleanup_attempts_core_backend_normal_after_scope_failure(self):
        self.root.joinpath('auth-bridge').mkdir();saved={'pid':999999,'starttime':'TEST_ONLY'}
        o.write(self.root/'auth-state.json',{'status':'blocked','core_witness':saved,'native_runtime':{'backend_witness':{'pid':999998}},'normal_before':{'test_only':True}})
        host=Mock();host.normal.return_value={'test_only':True}
        with patch.object(a,'stop_scopes',side_effect=o.Refused('TEST ONLY')),patch.object(a,'stop_owned_core',side_effect=o.Refused('TEST ONLY core')) as stop,patch.object(a,'scope_readbacks',return_value=['TEST_ONLY_scope_readback']),patch.object(o,'witness',return_value={'pid':999999}) as witness:
            result=a.cleanup(self.root,host)
        stop.assert_called_once();host.normal.assert_called_once()
        self.assertEqual([x.args[0] for x in witness.call_args_list],[999999,999998])
        self.assertTrue({'scope_stop','core_stop','core_final_readback','backend_final_readback','TEST_ONLY_scope_readback'}.issubset(result['cleanup_errors']))
    def test_cleanup_reused_core_never_pidfd_signalled(self):
        with patch.object(o,'witness',return_value={'pid':999999,'starttime':'REUSED'}),patch.object(os,'pidfd_open') as pidfd:
            with self.assertRaisesRegex(o.Refused,'PID_REUSE'): a.stop_owned_core(self.root,{'pid':999999,'starttime':'TEST_ONLY'})
        pidfd.assert_not_called()
    def test_cleanup_errors_sticky_idempotent_and_keys_erased(self):
        directory=self.root/'auth-bridge';directory.mkdir();directory.joinpath('client.key').write_text('TEST ONLY')
        o.write(self.root/'auth-state.json',{'status':'blocked','normal_before':{'test_only':True}})
        host=Mock();host.normal.return_value={'test_only':True}
        with patch.object(a,'stop_scopes',return_value=['TEST_ONLY_scope_stop']),patch.object(a,'scope_readbacks',return_value=[]):
            first=a.cleanup(self.root,host);second=a.cleanup(self.root,host)
        self.assertEqual(first,second);self.assertFalse(directory.joinpath('client.key').exists())
    def test_readiness_starting_ready_order(self):
        calls=[];phases=iter(['starting','starting','ready'])
        def rpc(method):
            calls.append(method)
            return {'phase':next(phases)} if method=='agent.runtime.get' else {'phase':'starting'}
        with patch.object(o.time,'sleep'): self.assertEqual(o.wait_ready(rpc)['phase'],'ready')
        self.assertEqual(calls,['agent.runtime.ensure']+['agent.runtime.get']*3)
    def test_readiness_immediately_ready(self):
        call=Mock(return_value={'phase':'ready'});o.wait_ready(call)
        self.assertEqual([c.args[0] for c in call.call_args_list],['agent.runtime.ensure','agent.runtime.get'])
    def test_readiness_failed_cancelled_unknown_refused(self):
        for phase in ('failed','cancelled','stopped','unknown'):
            with self.subTest(phase=phase),self.assertRaises(o.Refused): o.wait_ready(Mock(return_value={'phase':phase}))
    def test_readiness_timeout_has_no_provider_consumer(self):
        call=Mock(return_value={'phase':'starting'})
        with patch.object(o.time,'monotonic',side_effect=[0,0,31]),patch.object(o.time,'sleep'),self.assertRaisesRegex(o.Refused,'deadline'): o.wait_ready(call)
        self.assertNotIn('agent.providers.status',[c.args[0] for c in call.call_args_list])
    def test_readiness_signal_propagates_no_retry(self):
        call=Mock(side_effect=[{},o.Refused('TEST ONLY signal')])
        with self.assertRaises(o.Refused): o.wait_ready(call)
        self.assertEqual(call.call_count,2)
    def recovery(self,host):
        o.write(self.root/'state.json',{'mode':None,'modes':{},'disruption_armed':True,'pause_armed':True,'runner_before':'active','normal_before':{'test_only':True}})
        return o.recover(self.root,host)
    def test_successful_removal_reload_precedes_normal_login(self):
        host=RecoveryHost(self.root);drop=self.root/'drop';drop.write_text('TEST ONLY')
        real=o.Host(self.root)
        real.system=lambda *args,**kw: host.events.append('reload')
        def remove(): host.events.append('remove');return real.remove_override()
        host.remove_override=remove
        with patch.object(o,'DROPIN',drop): result=self.recovery(host)
        self.assertEqual(result['recovery_status'],'verified')
        self.assertLess(host.events.index('remove'),host.events.index('reload'));self.assertLess(host.events.index('reload'),host.events.index('relogin'))
    def test_reload_failure_forbids_login_but_restores_gdm_runner(self):
        host=RecoveryHost(self.root);real=o.Host(self.root)
        real.system=Mock(side_effect=o.Refused('TEST ONLY reload'));host.remove_override=real.remove_override
        with patch.object(o,'DROPIN',self.root/'absent'): result=self.recovery(host)
        self.assertEqual(result['recovery_status'],'needs_human');self.assertNotIn('relogin',host.events);self.assertIn('gdm',host.events);self.assertIn('start',host.events)
    def test_remaining_override_forbids_reload_and_login(self):
        host=o.Host(self.root);host.system=Mock();drop=self.root/'drop';drop.write_text('TEST ONLY')
        with patch.object(o,'DROPIN',drop),patch.object(Path,'unlink'),self.assertRaisesRegex(o.Refused,'remains'): host.remove_override()
        host.system.assert_not_called()
    def test_live_normal_state_need_normal_unknown(self):
        host=o.Host(self.root)
        with patch.object(o,'DROPIN',self.root/'absent'),patch.object(host,'normal',return_value={}) as normal:
            self.assertEqual(host.normal_state(),'NORMAL');normal.assert_called_once()
        with patch.object(o,'DROPIN',self.root/'absent'),patch.object(host,'normal',side_effect=o.Refused('TEST ONLY private store')):
            self.assertEqual(host.normal_state(),'NEED')
        with patch.object(o,'DROPIN',self.root/'absent'),patch.object(host,'normal',side_effect=FileNotFoundError()):
            self.assertEqual(host.normal_state(),'UNKNOWN')
    def test_partial_canonical_restore_still_attempts_login_and_preserves_failure(self):
        host=RecoveryHost(self.root);host.needs_relogin=lambda: True
        host.remove_override=lambda: True
        host.relogin=Mock(side_effect=o.Refused('TEST ONLY no autologin'))
        result=self.recovery(host)
        self.assertEqual(result['recovery_status'],'needs_human');host.relogin.assert_called_once();self.assertIn('gdm',host.events)
    def test_canonical_copy_remove_failure_does_not_execute_login(self):
        original=(Path(o.__file__).parents[2]/'tests/g3/reference/seat.sh').read_text()
        copy=o.adapt_seat(original,self.root/'candidate',self.root/'ops/g3_ops.py',ID)
        # Execute the actual adapted block with TEST ONLY shell functions.
        block=copy[copy.index('    local restored=1'):copy.index('    if [[ "$restored" == 0 ]]')]
        for fail in ('remove','reload'):
            stub='rm(){ '+('return 1;' if fail=='remove' else 'return 0;')+' }; systemctl(){ return 1; }; sudo(){ echo UNSAFE_LOGIN; }; wait_login(){ echo UNSAFE_LOGIN; }; '\
                 'f(){ local dropin="'+str(self.root/'absent')+'" private_restored=0; '+block+' echo status=$restored; }; f'
            result=subprocess.run(['bash','-c',stub],capture_output=True,text=True)
            self.assertEqual(result.returncode,0);self.assertNotIn('UNSAFE_LOGIN',result.stdout);self.assertIn('status=1',result.stdout)
    def test_worker_identity_table_independent_of_name(self):
        origin={'pid':999999,'starttime':'OLD'}
        for current,workers,expected in [(None,[],True),({**origin,'worker':False},[],False),({**origin,'worker':True},[origin],False)]:
            with self.subTest(current=current),patch.object(o,'witness',return_value=current): self.assertEqual(o.worker_gate(origin,workers),expected)
        for current in ({'pid':999999,'starttime':'NEW','worker':True},{'pid':999999,'starttime':'NEW','worker':False}):
            with self.subTest(current=current),patch.object(o,'witness',return_value=current),self.assertRaises(o.Refused): o.worker_gate(origin,[])
    def test_worker_unreadable_refuses_before_side_effects(self):
        with patch.object(o,'witness',side_effect=PermissionError()),self.assertRaisesRegex(o.Refused,'unreadable'): o.worker_gate({'pid':999999,'starttime':'OLD'},[])
    def test_partial_proc_witness_never_guessed_gone(self):
        proc=self.root/'proc';p=proc/'999999';p.mkdir(parents=True)
        with self.assertRaises(o.Refused): o.witness(999999,proc)
        p.joinpath('stat').write_text('999999 (TEST ONLY) '+' '.join(['0']*19+['OLD']))
        with self.assertRaises(o.Refused): o.witness(999999,proc)
    def test_normal_bootstrap_and_import_match_both_pinned_sources(self):
        repo=Path(o.__file__).parents[2]
        for name,expected in o.BOOTSTRAP_HASHES.items():
            for source in (o.SOURCE,'d49387f94cea3f37207224463895be1b4e95d8ec'):
                data=subprocess.check_output(['git','-C',str(repo),'show',source+':'+name])
                self.assertEqual(o.hashlib.sha256(data).hexdigest(),expected)
            self.assertEqual(o.sha(o.HERE/'bootstrap'/name),expected)
    def test_private_relay_missing_candidate_never_uses_normal_helper(self):
        host=o.Host(self.root)
        with patch.object(host,'command') as command,self.assertRaises(FileNotFoundError): host.relay('agent.providers.status',private=True)
        command.assert_not_called()
    def test_bootstrap_hash_change_refused_before_command(self):
        host=o.Host(self.root)
        with patch.object(o,'sha',return_value='0'*64),patch.object(host,'command') as command,self.assertRaisesRegex(o.Refused,'bootstrap'): host.profile()
        command.assert_not_called()
    def test_detached_bootstrap_remains_present_without_work_checkout(self):
        import shutil
        frozen=self.root/'ops';shutil.copytree(o.HERE/'bootstrap',frozen/'bootstrap')
        with patch.object(o,'HERE',frozen): self.assertTrue(o.normal_helper().is_file())

class FinalLifecycleEdges(unittest.TestCase):
    def setUp(self):
        temp=tempfile.TemporaryDirectory(prefix='TEST_ONLY_final_edges_');self.addCleanup(temp.cleanup)
        self.root=Path(temp.name)/('q'+ID);self.root.mkdir();self.root.joinpath('auth-bridge').mkdir()
    def test_probe_rpc_failure_cancels_exact_turn_restores_preferences(self):
        calls=[];gets=0;cancelled=False
        def call(method,params=None,**kw):
            nonlocal gets,cancelled
            calls.append((method,params))
            if method=='agent.settings.describe': return {'revision':1,'enabled':False,'model':a.MODEL,'reasoning_effort':a.EFFORT}
            if method=='agent.settings.patch': return {**params['settings'],'revision':2}
            if method=='desktop.profiles.get': return {'revision':{'document_sha256':'TEST_ONLY'}}
            if method=='agent.sessions.create': return {'session_id':'TEST_ONLY_SESSION'}
            if method=='agent.turns.submit': return {'turn_id':'TEST_ONLY_TURN'}
            if method=='agent.turns.get':
                gets+=1
                if gets==1: raise o.Refused('BLOCKED_TEST_ONLY_RPC')
                return {'state':'cancelled' if cancelled else 'running'}
            if method=='agent.turns.cancel': cancelled=True;return {}
            raise AssertionError('TEST ONLY unexpected API')
        core=Mock();core.call.side_effect=call
        with self.assertRaisesRegex(o.Refused,'TEST_ONLY_RPC'): a.minimal_probe(core)
        self.assertIn(('agent.turns.cancel',{'turn_id':'TEST_ONLY_TURN'}),calls)
        self.assertFalse(calls[-1][1]['settings']['enabled'])
    def test_revoke_rechecks_ready_after_disabled_preferences(self):
        events=[];core=RealmCore();core.authenticated=True;call=core.call
        core.ready=lambda **kw: events.append('ready')
        core.call=lambda method,*args,**kw: (events.append(method),call(method,*args,**kw))[1]
        a.revoke(core)
        self.assertEqual(events,['ready','agent.providers.logout','agent.providers.status'])
        self.assertFalse(core.authenticated)
    def test_scope_active_error_does_not_skip_process_readback(self):
        host=Mock();events=[]
        def command(argv, **kw):
            events.append((argv[2],argv[3]))
            return subprocess.CompletedProcess(argv,0,'LoadState=loaded\nActiveState=active\nControlGroup=\n','')
        host.command.side_effect=command
        with patch.object(o,'Host',return_value=host): errors=a.scope_readbacks(self.root,ID)
        self.assertEqual(len(errors),3)
        self.assertEqual([e[1] for e in events if e[0]=='show'],a.owned_units(ID))
    def test_exact_core_pidfd_signal_and_final_gone_readback(self):
        saved={'pid':999999,'starttime':'TEST_ONLY'}
        with patch.object(o,'witness',side_effect=[saved,saved,None,None]),patch.object(Path,'resolve',return_value=self.root/'candidate/target/release/ditto-core'),patch.object(os,'pidfd_open',return_value=123) as pidfd,patch.object(signal,'pidfd_send_signal') as send,patch.object(os,'close') as close:
            a.stop_owned_core(self.root,saved)
        pidfd.assert_called_once_with(999999);send.assert_called_once_with(123,signal.SIGTERM);close.assert_called_once_with(123)
    def test_abrupt_pending_cleanup_reopens_only_same_bound_realm_for_logout(self):
        realm=self.root/'realm'
        state={'source':o.SOURCE,'ops_sha':'a'*40,'status':'awaiting_browser','auth_lifecycle':'pending','realm':str(realm),'normal_before':{'test_only':True}}
        o.write(self.root/'auth-state.json',state)
        core=RealmCore();core.authenticated=True
        def enter():
            current=o.read(self.root/'auth-state.json');current['core_witness']={'pid':999999,'starttime':'TEST_ONLY'};o.write(self.root/'auth-state.json',current);return core
        cm=Mock();cm.__enter__=Mock(side_effect=enter);cm.__exit__=Mock(return_value=False)
        host=Mock();host.normal.return_value={'test_only':True}
        with patch.object(a,'stop_scopes',return_value=[]),patch.object(a,'scope_readbacks',return_value=[]),patch.object(o,'verify_stage',return_value={'ops_sha':'a'*40}),patch.object(a,'realm_path',return_value=realm),patch.object(a,'realm_guard'),patch.object(a,'NativeCore',return_value=cm) as constructor:
            result=a.cleanup(self.root,host)
        constructor.assert_called_once_with(self.root,realm,ID)
        self.assertFalse(core.authenticated);self.assertEqual(result['auth_lifecycle'],'revoked');self.assertEqual(result['status'],'blocked')
    def test_abrupt_revocation_source_mismatch_does_not_start_core(self):
        o.write(self.root/'auth-state.json',{'source':'WRONG','ops_sha':'a'*40,'status':'blocked','auth_lifecycle':'completed','normal_before':{'test_only':True}})
        host=Mock();host.normal.return_value={'test_only':True}
        with patch.object(a,'stop_scopes',return_value=[]),patch.object(a,'scope_readbacks',return_value=[]),patch.object(o,'verify_stage',return_value={'ops_sha':'a'*40}),patch.object(a,'NativeCore') as core:
            result=a.cleanup(self.root,host)
        core.assert_not_called();self.assertEqual(result['status'],'needs_human');self.assertIn('auth_revocation',result['cleanup_errors'])
    def test_live_cleanup_revokes_before_scope_or_core_stop(self):
        o.write(self.root/'auth-state.json',{'status':'blocked','auth_lifecycle':'completed','normal_before':{'test_only':True}})
        events=[];host=Mock();host.normal.return_value={'test_only':True}
        def live(root,state): events.append('logout_status');state['auth_lifecycle']='revoked';return True
        with patch.object(a,'revoke_live_core',side_effect=live),patch.object(a,'stop_scopes',side_effect=lambda *args: events.append('scopes') or []),patch.object(a,'stop_owned_core',side_effect=lambda *args:events.append('core')),patch.object(a,'scope_readbacks',return_value=[]):
            result=a.cleanup(self.root,host)
        self.assertEqual(events,['logout_status','scopes','core']);self.assertEqual(result['auth_lifecycle'],'revoked')
    def test_live_revocation_failure_still_attempts_all_cleanup_and_needs_human(self):
        o.write(self.root/'auth-state.json',{'status':'blocked','auth_lifecycle':'completed','normal_before':{'test_only':True},'reason':'BLOCKED_TEST_ONLY_ORIGINAL'})
        host=Mock();host.normal.return_value={'test_only':True}
        with patch.object(a,'revoke_live_core',side_effect=o.Refused('TEST ONLY revoke')),patch.object(a,'stop_scopes',return_value=[]) as scopes,patch.object(a,'stop_owned_core') as core,patch.object(a,'scope_readbacks',return_value=[]):
            result=a.cleanup(self.root,host)
        scopes.assert_called_once();core.assert_called_once();host.normal.assert_called_once()
        self.assertEqual(result['status'],'needs_human');self.assertEqual(result['reason'],'BLOCKED_TEST_ONLY_ORIGINAL')
        self.assertIn('live_auth_revocation',result['cleanup_errors'])
    def test_unknown_lifecycle_needs_human(self):
        o.write(self.root/'auth-state.json',{'status':'blocked','auth_lifecycle':'arbitrary','normal_before':{'test_only':True}})
        host=Mock();host.normal.return_value={'test_only':True}
        with patch.object(a,'stop_scopes',return_value=[]),patch.object(a,'scope_readbacks',return_value=[]): result=a.cleanup(self.root,host)
        self.assertIn('auth_lifecycle_unknown',result['cleanup_errors']);self.assertEqual(result['status'],'needs_human')
    def test_origin_alive_deadline_never_pauses_runner(self):
        origin={'pid':999999,'starttime':'TEST_ONLY','worker':False}
        o.write(self.root/'state.json',{'origin':origin,'modes':{m:'not_run' for m in o.MODES},'mode':None})
        host=Mock();host.workers.return_value=[]
        with patch.object(o,'verify_stage'),patch.object(o,'witness',return_value=origin),patch.object(o.time,'monotonic',side_effect=[0,301]),self.assertRaises(o.Refused): o.control(self.root,host)
        host.pause_runner.assert_not_called();host.system.assert_not_called()
        self.assertEqual(o.read(self.root/'state.json')['failure_detail'],'origin Worker exit deadline')
    def test_origin_reused_nonworker_control_refuses_before_pause(self):
        origin={'pid':999999,'starttime':'OLD'}
        o.write(self.root/'state.json',{'origin':origin,'modes':{m:'not_run' for m in o.MODES},'mode':None})
        host=Mock();host.workers.return_value=[]
        with patch.object(o,'verify_stage'),patch.object(o,'witness',return_value={'pid':999999,'starttime':'NEW','worker':False}),self.assertRaises(o.Refused): o.control(self.root,host)
        host.pause_runner.assert_not_called();host.normal.assert_not_called();host.system.assert_not_called()

class BootstrapAndNativeContracts(unittest.TestCase):
    """Actual Host.normal/preflight/command resolution, injected OS readbacks."""
    def setUp(self):
        temp=tempfile.TemporaryDirectory(prefix='TEST_ONLY_bootstrap_')
        self.addCleanup(temp.cleanup)
        self.root=Path(temp.name)/('q'+ID);self.root.mkdir()
        self.stack=ExitStack();self.addCleanup(self.stack.close)
        self.installed=self.root/'installed';self.exe=self.installed/'target/release/ditto-core'
        self.template=self.root/'template';self.template.write_text('TEST ONLY')
        self.gdm=self.root/'gdm';self.gdm.write_text('TEST ONLY')
        self.paths=[];self.environment=b'HOME=/home/neil\0';self.active=True;self.bad_exe=False;self.db_schema=4;self.clone_failure=False
        host=self.host=o.Host(self.root)
        host.system=lambda *args,**kw: 'XDG_SESSION_ID=TEST_ONLY_SESSION' if args[0]=='show-environment' else '999999'
        def command(argv,**kw):
            if argv[0]=='python3':
                self.paths.append(Path(argv[1]));self.assertTrue(self.paths[-1].is_file())
                reply={'result':{'profile':{'profile_id':'TEST_ONLY'},'revision':{'document_sha256':'a'*64}}}
                return subprocess.CompletedProcess(argv,0,json.dumps(reply),'')
            if argv[0]=='git':
                if argv[1]=='clone':
                    self.clone_failure=True
                    raise o.Refused('TEST ONLY clone failed after valid preflight')
                value='d49387f94cea3f37207224463895be1b4e95d8ec' if 'rev-parse' in argv else ''
            elif argv[0]=='loginctl':
                value='TEST_ONLY_SESSION 1000 neil seat0' if argv[1]=='list-sessions' else 'User=1000\nType=wayland\nSeat=seat0\nActive='+('yes' if self.active else 'no')
            elif argv[0]=='busctl': value='b false'
            elif argv[0].endswith('/node'): value='v22.23.2'
            elif argv[0]=='pnpm': value='10.11.0'
            else: value=''
            return subprocess.CompletedProcess(argv,0,value,'')
        host.command=command
        realresolve=Path.resolve;realread=Path.read_bytes;realsha=o.sha
        def resolve(path,*args,**kw):
            if str(path)=='/proc/999999/exe': return self.root/'candidate/target/release/ditto-core' if self.bad_exe else self.exe
            return realresolve(path,*args,**kw)
        def read(path):
            return self.environment if str(path)=='/proc/999999/environ' else realread(path)
        def digest(path):
            if Path(path) in (self.exe,Path('/proc/999999/exe')): return '1'*64
            if Path(path)==o.CODEX: return o.CODEX_SHA
            if Path(path)==self.template: return o.TEMPLATE_SHA
            if Path(path)==self.gdm: return o.GDM_SHA
            return realsha(path)
        self.stack.enter_context(patch.object(Path,'resolve',resolve))
        self.stack.enter_context(patch.object(Path,'read_bytes',read))
        self.stack.enter_context(patch.object(o,'sha',side_effect=digest))
        self.stack.enter_context(patch.object(o,'schema',side_effect=lambda *args:self.db_schema))
        self.stack.enter_context(patch.object(o,'INSTALLED',self.installed))
        self.stack.enter_context(patch.object(o,'TEMPLATE',self.template))
        self.stack.enter_context(patch.object(o,'GDM',self.gdm))
        self.stack.enter_context(patch.object(o,'DROPIN',self.root/'absent'))
        # stat requires actual task-only fake files; normal bytes are not read.
        self.exe.parent.mkdir(parents=True);self.exe.write_text('TEST ONLY executable')
    def test_fresh_preflight_actual_normal_resolver_has_no_candidate_dependency(self):
        report=o.preflight(self.root,self.host)
        self.assertTrue(report['seat0']);self.assertTrue(self.paths)
        self.assertEqual(report['normal_helper']['path'],str(o.normal_helper()))
        self.assertEqual(report['normal_helper']['sha256'],o.BOOTSTRAP_HASHES['tests/g1/lib/gui.py'])
        self.assertFalse((self.root/'candidate').exists())
    def test_clone_failure_preserves_callable_normal_baseline(self):
        with patch.object(o.shutil,'disk_usage',return_value=Mock(free=20*1024**3)),self.assertRaisesRegex(o.Refused,'clone failed'): o.stage(self.root,self.host)
        self.assertTrue(self.clone_failure);self.assertEqual(self.host.normal()['schema'],4)
        self.assertFalse((self.root/'candidate').exists())
    def test_normal_live_private_store_refused_after_files_removed(self):
        self.environment+=b'DITTO_DATA_DIR=/TEST_ONLY/private\0'
        self.assertEqual(self.host.normal_state(),'NEED')
    def test_normal_live_candidate_exe_refused_after_files_removed(self):
        self.bad_exe=True
        self.assertEqual(self.host.normal_state(),'NEED')
    def test_normal_inactive_seat_refused_after_files_removed(self):
        self.active=False
        self.assertEqual(self.host.normal_state(),'NEED')
    def test_normal_migrated_schema_refused(self):
        self.db_schema=5
        self.assertEqual(self.host.normal_state(),'NEED')
    def test_normal_relay_missing_refused_after_files_removed(self):
        command=self.host.command
        self.host.command=lambda argv,**kw: (_ for _ in ()).throw(o.Refused('TEST ONLY relay absent')) if argv[0]=='python3' else command(argv,**kw)
        self.assertEqual(self.host.normal_state(),'NEED')

if __name__=='__main__': unittest.main(verbosity=2)
