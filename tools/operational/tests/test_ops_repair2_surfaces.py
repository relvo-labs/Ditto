"""TEST ONLY A/B/C sibling witnesses, no OS/provider/Home actions."""
from contextlib import ExitStack
import itertools
import json
from pathlib import Path
import socket
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch
from test_ops_repair2 import o,a,b,ID,VirtualClock,ReadinessFixture

class Repair2Surfaces(unittest.TestCase):
    def setUp(self):
        temp=tempfile.TemporaryDirectory(prefix='TEST_ONLY_repair2_edges_');self.addCleanup(temp.cleanup)
        self.root=Path(temp.name)/('q'+ID);self.root.mkdir();self.root.joinpath('auth-bridge').mkdir()
    def scopes(self,load='loaded',active='inactive',group='',rc=1,body=None,residual=False):
        calls=[]
        def command(argv,**kw):
            calls.append(argv)
            return subprocess.CompletedProcess(argv,rc if 'stop' in argv else 0,body if body is not None else 'LoadState='+load+'\nActiveState='+active+'\nControlGroup='+group+'\n','')
        with patch.object(o.subprocess,'run',side_effect=command),patch.object(Path,'exists',return_value=True),patch.object(Path,'read_text',return_value='999999' if residual else ''):
            errors=a.stop_scopes(self.root,ID)
        self.assertEqual(len([v for v in calls if 'stop' in v]),3)
        self.assertEqual(len([v for v in calls if 'show' in v]),3)
        return errors
    def test_A_loaded_stop_failure_with_empty_cgroup_is_failure(self): self.assertTrue(self.scopes())
    def test_A_nonzero_unknown_explicit_absence_is_clean(self): self.assertEqual(self.scopes(load='not-found'),[])
    def test_A_empty_error_text_never_proves_absence(self): self.assertTrue(self.scopes(body=''))
    def test_A_unknown_unit_with_cgroup_never_proves_absence(self):
        self.assertTrue(self.scopes(load='not-found',group='/user.slice/user-1000.slice/user@1000.service/app.slice/ditto-g3-auth-q'+ID+'-agent.scope',residual=True))
    def test_A_loaded_residual_process_still_fails(self):
        calls=[]
        def command(argv,**kw):
            calls.append(argv)
            if 'stop' in argv: return subprocess.CompletedProcess(argv,1,'','')
            unit=argv[3]
            group='/user.slice/user-1000.slice/user@1000.service/app.slice/'+unit
            return subprocess.CompletedProcess(argv,0,'LoadState=loaded\nActiveState=inactive\nControlGroup='+group+'\n','')
        with patch.object(o.subprocess,'run',side_effect=command),patch.object(Path,'exists',return_value=True),patch.object(Path,'read_text',return_value='999999'):
            errors=a.stop_scopes(self.root,ID)
        self.assertEqual(len(errors),6)
        self.assertTrue(all(any(unit in error for error in errors) for unit in a.owned_units(ID)))
    def test_A_active_unit_process_file_still_read(self):
        host=o.Host(self.root);unit=a.owned_units(ID)[0]
        props='LoadState=loaded\nActiveState=active\nControlGroup=/user.slice/user-1000.slice/user@1000.service/app.slice/'+unit+'\n'
        with patch.object(o.subprocess,'run',return_value=subprocess.CompletedProcess([],0,props,'')),patch.object(Path,'exists',return_value=True),patch.object(Path,'read_text',return_value='999999') as processes,self.assertRaises(o.Refused): a.scope_snapshot(host,unit)
        processes.assert_called_once()
    def test_B_draining_failed_refuses_no_logout(self):
        with ExitStack() as stack:
            f=ReadinessFixture(self.root,stack,['draining','failed'])
            with self.assertRaises(o.Refused): a.revoke(f.core)
        self.assertNotIn('agent.providers.logout',f.events);self.assertEqual(f.events.count('agent.runtime.ensure'),1)
    def test_B_draining_deadline_refuses_no_logout(self):
        clock=VirtualClock()
        with ExitStack() as stack:
            f=ReadinessFixture(self.root,stack,itertools.repeat('draining'))
            stack.enter_context(patch.object(o.time,'monotonic',clock.now));stack.enter_context(patch.object(o.time,'sleep',clock.advance))
            with self.assertRaisesRegex(o.Refused,'deadline'): a.revoke(f.core)
        self.assertLessEqual(clock.value,30.001);self.assertNotIn('agent.providers.logout',f.events)
    def test_B_strict_consumer_still_refuses_draining(self):
        with ExitStack() as stack:
            f=ReadinessFixture(self.root,stack)
            with self.assertRaisesRegex(o.Refused,'draining'): f.core.ready()
        self.assertEqual(f.events,['agent.runtime.ensure'])
    def test_B_new_generation_drain_is_not_restarted_again(self):
        with ExitStack() as stack:
            f=ReadinessFixture(self.root,stack,['draining','stopped','starting','draining'])
            with self.assertRaises(o.Refused): a.revoke(f.core)
        self.assertEqual(f.events.count('agent.runtime.ensure'),2);self.assertNotIn('agent.providers.logout',f.events)
    def state(self,lifecycle='completed'):
        value={'status':'blocked','auth_lifecycle':lifecycle,'normal_before':{'test_only':True},'test_only':True,'reason':'BLOCKED_TEST_ONLY_ORIGINAL'}
        o.write(self.root/'auth-state.json',value)
    def test_C_expired_steps_are_recorded_and_final_result_saved(self):
        self.state();clock=VirtualClock();host=o.Host(self.root);host.normal=Mock(return_value={'test_only':True})
        with patch.object(o.time,'monotonic',clock.now),patch.object(b,'erase_keys',side_effect=lambda *args:clock.advance(151)):
            result=a.cleanup(self.root,host)
        host.normal.assert_not_called()
        self.assertFalse(result['cleanup_in_progress']);self.assertEqual(result['cleanup_pending'],[])
        for name in a.CLEANUP_PHASES:
            self.assertEqual(result['cleanup_steps'][name],'budget_exhausted' if name not in ('core_final_readback','backend_final_readback') else 'not_applicable')
        self.assertEqual(result['reason'],'BLOCKED_TEST_ONLY_ORIGINAL')
        self.assertEqual(o.read(self.root/'auth-state.json'),result)
    def test_C_kill_mid_step_leaves_incomplete_failure_journal(self):
        self.state();host=o.Host(self.root)
        class TestOnlyKill(BaseException): pass
        with patch.object(host,'system',return_value=''),patch.object(a,'revoke_live_core',side_effect=TestOnlyKill),self.assertRaises(TestOnlyKill): a.cleanup(self.root,host)
        state=o.read(self.root/'auth-state.json')
        self.assertTrue(state['cleanup_in_progress']);self.assertFalse(state['native_stopped'])
        self.assertIn('cleanup_incomplete',state['cleanup_errors']);self.assertIn('normal_final_readback',state['cleanup_pending'])
    def test_C_host_command_caps_and_exhaustion_reach_real_command_path(self):
        clock=VirtualClock();host=o.Host(self.root);seen=[]
        def run(argv,timeout,**kw): seen.append(timeout);clock.advance(timeout);raise subprocess.TimeoutExpired('TEST ONLY',timeout)
        token=o.AUTH_CLEANUP_END.set(2)
        try:
            with patch.object(o.time,'monotonic',clock.now),patch.object(o.subprocess,'run',side_effect=run):
                with self.assertRaises(subprocess.TimeoutExpired): host.command(['TEST_ONLY'])
                with self.assertRaisesRegex(o.Refused,'BUDGET'): host.command(['TEST_ONLY'])
        finally: o.AUTH_CLEANUP_END.reset(token)
        self.assertEqual(seen,[2])
    def test_C_rpc_drip_cannot_reset_total_timeout(self):
        clock=VirtualClock();core=a.NativeCore.__new__(a.NativeCore);core.runtime=self.root
        class TestOnlySocket:
            def __enter__(self): return self
            def __exit__(self,*args): pass
            def settimeout(self,value): self.timeout=value
            def connect(self,*args): pass
            def sendall(self,*args): pass
            def recv(self,*args): clock.advance(min(.75,self.timeout));return b' '
        token=o.AUTH_CLEANUP_END.set(2)
        try:
            with patch.object(o.time,'monotonic',clock.now),patch.object(socket,'socket',return_value=TestOnlySocket()),self.assertRaises(o.Refused): core.call('TEST_ONLY',timeout=20)
        finally: o.AUTH_CLEANUP_END.reset(token)
        self.assertEqual(clock.value,2)
    def test_C_slow_sequence_reserves_normal_readback_and_persists_all_failures(self):
        self.state();clock=VirtualClock();host=o.Host(self.root);commands=[]
        def run(argv,timeout=10,**kw):
            commands.append((argv,timeout));clock.advance(timeout)
            if argv[0]=='TEST_ONLY_normal': return subprocess.CompletedProcess(argv,0,'','')
            raise subprocess.TimeoutExpired('TEST ONLY',timeout)
        host.normal=lambda: host.command(['TEST_ONLY_normal'],timeout=10) and {'test_only':True}
        def slow_revoke(*args):
            clock.advance(o.bounded_timeout(30));clock.advance(o.bounded_timeout(10));o.bounded_timeout(1)
        with patch.object(o.time,'monotonic',clock.now),patch.object(o.time,'sleep',clock.advance),patch.object(o.subprocess,'run',side_effect=run),patch.object(a,'revoke_live_core',side_effect=slow_revoke),patch.object(a,'stop_owned_core'):
            result=a.cleanup(self.root,host)
        self.assertLess(clock.value,150);self.assertTrue(any(argv[0]=='TEST_ONLY_normal' for argv,timeout in commands))
        self.assertEqual(result['cleanup_steps']['normal_final_readback'],'passed')
        self.assertEqual(set(result['cleanup_steps']),set(a.CLEANUP_PHASES));self.assertFalse(result['cleanup_pending'])
        self.assertTrue(all(any(unit in error for error in result['cleanup_errors']) for unit in a.owned_units(ID)))
        self.assertEqual(result['status'],'needs_human');self.assertEqual(result['reason'],'BLOCKED_TEST_ONLY_ORIGINAL')
        self.assertEqual(o.read(self.root/'auth-state.json'),result)

    def test_C_real_sqlite_busy_wait_obeys_remaining_budget(self):
        import sqlite3
        import time
        database=self.root/'TEST_ONLY_locked.db'
        with sqlite3.connect(database) as locked:
            locked.execute('PRAGMA user_version=4')
            locked.execute('BEGIN EXCLUSIVE')
            start=time.monotonic();token=o.AUTH_CLEANUP_END.set(start+.03)
            try:
                with self.assertRaises(sqlite3.OperationalError): o.schema(database)
            finally:
                o.AUTH_CLEANUP_END.reset(token)
                locked.rollback()
            self.assertLess(time.monotonic()-start,1)

if __name__=='__main__': unittest.main(verbosity=2)
