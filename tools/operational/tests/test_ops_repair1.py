"""TEST ONLY semantic counterexamples. No native/provider/desktop receipts."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch, Mock
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import g3_ops as o
import g3_auth as a
import g3_device_bridge as b

ID = '123456789'

class RealmCore:
    """TEST ONLY: completed notification clears pending, keyring survives stop."""
    def __init__(self):
        self.authenticated = False
        self.calls = []
    def ready(self, **kwargs):
        return {'test_only': True}
    def call(self, method, params=None, **kw):
        value = self._result(method, params, **kw)
        # Pinned17f Core dispatch wraps EVERY object result; no native proof.
        if type(value) is dict:
            return {**value, "_meta": {"observed_seq": 1, "profile_revision": None,
                                      "readback_verified": False, "handled_us": 1}}
        return value
    def _result(self, method, params=None, **kw):
        self.calls.append(method)
        if method == 'agent.providers.status':
            return {'available': True, 'provider': 'codex-app-server', 'authenticated': self.authenticated,
                    'models': [{'id': a.MODEL, 'reasoning_efforts': [a.EFFORT]}]}
        if method == 'agent.providers.login':
            self.authenticated = True
            return {'login_id': 'TEST_ONLY', 'auth_url': 'https://auth.openai.com/codex/device',
                    'user_code': 'TEST-1234', 'expires_at_ms': b.now_ms() + 120000}
        if method == 'agent.providers.logout':
            self.authenticated = False
            return {'completed': True}
        return {'completed': False}

class RecoveryHost:
    def __init__(self, root):
        self.root, self.events = root, []
    def needs_relogin(self): return True
    def restore_private(self, state): self.events.append('private')
    def remove_override(self):
        self.events.append('remove')
        raise o.Refused('TEST ONLY remove failed')
    def relogin(self): self.events.append('relogin')
    def restore_gdm(self): self.events.append('gdm')
    def normal(self): self.events.append('normal'); return {'test_only': True}
    def resume_listener(self, state): self.events.append('listener')
    def system(self, *args, **kw): self.events.append(args[0]); return 'active'

class RepairCounterexamples(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='TEST_ONLY_repair1_')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / ('q' + ID)
        self.root.mkdir()
    def receipt(self):
        return {'qualification_id': ID, 'flow_id': 'a'*32, 'expires_at_ms': b.now_ms()+180000}
    def test_F1_completed_probe_failure_revokes(self):
        core = RealmCore()
        with patch.object(a, 'minimal_probe', side_effect=o.Refused('BLOCKED_TEST_ONLY_PROBE')):
            with self.assertRaises(o.Refused):
                a.device_flow(core, Mock(), self.receipt(), lambda **v: None)
        self.assertFalse(core.authenticated, 'completed keyring authentication survives failed probe')
        self.assertLess(core.calls.index('agent.providers.logout'), core.calls.index('agent.runtime.stop'))
        self.assertEqual(core.calls[core.calls.index('agent.providers.logout')+1], 'agent.providers.status')
    def test_F2_cleanup_attempts_normal_after_scope_failure(self):
        self.root.joinpath('auth-bridge').mkdir()
        o.write(self.root/'auth-state.json', {'status': 'blocked', 'normal_before': {'test_only': True}})
        host = Mock()
        host.normal.return_value = {'test_only': True}
        with patch.object(a, 'stop_scopes', side_effect=o.Refused('TEST ONLY first scope')), patch.object(a, 'scope_readbacks', return_value=[]):
            result = a.cleanup(self.root, host)
        self.assertEqual(result['status'], 'needs_human')
        self.assertTrue(host.normal.called, 'independent normal readback skipped')
    def test_F3_enter_waits_before_provider_status(self):
        o.write(self.root/'state.json', {'mode': 'full'})
        self.root.joinpath('evidence/full').mkdir(parents=True)
        events = []
        host = Mock()
        def relay(method, params=None):
            events.append(method)
            if method == 'agent.runtime.get': return {'phase': 'ready'}
            if method == 'agent.providers.status':
                if 'agent.runtime.get' not in events: raise o.Refused('TEST ONLY Agent is starting')
                return {'authenticated': True}
            if method == 'desktop.permissions.list': return {'grants': []}
            return {}
        host.relay.side_effect = relay
        host.private_relay.side_effect = relay
        try: o.enter(self.root, host)
        except o.Refused: pass
        self.assertIn('agent.runtime.get', events, 'ensure was not awaited')
        self.assertLess(events.index('agent.runtime.get'), events.index('agent.providers.status'))
    def test_F4_remove_failure_forbids_relogin(self):
        o.write(self.root/'state.json', {'mode': None, 'modes': {}, 'disruption_armed': True, 'pause_armed': True,
                                      'runner_before': 'active', 'normal_before': {'test_only': True}})
        host = RecoveryHost(self.root)
        result = o.recover(self.root, host)
        self.assertEqual(result['recovery_status'], 'needs_human')
        self.assertNotIn('relogin', host.events, 'candidate dropin failure still relogins')
        self.assertIn('gdm', host.events)
        self.assertIn('listener', host.events)
    def test_F5_removed_files_do_not_prove_normal(self):
        self.root.joinpath('gdm-original.conf').write_text('TEST ONLY restored GDM')
        host = o.Host(self.root)
        with patch.object(o, 'DROPIN', self.root/'absent'), patch.object(o, 'GDM', self.root/'gdm-original.conf'), patch.object(host, 'normal', side_effect=o.Refused('TEST ONLY candidate executable')):
            self.assertTrue(host.needs_relogin(), 'files restored while private Core is still live')
    def test_F6_reused_nonworker_refuses(self):
        with patch.object(o, 'witness', return_value={'pid': 900, 'starttime': 'NEW', 'worker': False}):
            with self.assertRaises(o.Refused, msg='nonWorker reuse authorized pause'):
                o.worker_gate({'pid': 900, 'starttime': 'OLD'}, [])
    def test_F7_fresh_normal_helper_exists(self):
        host = o.Host(self.root)
        paths = []
        def command(argv, **kw):
            paths.append(Path(argv[1]))
            if not paths[-1].is_file(): raise o.Refused('TEST ONLY missing relay helper')
            return subprocess.CompletedProcess(argv, 0, json.dumps({'result': {'profile': {'profile_id': 'TEST_ONLY'}, 'revision': {'document_sha256': 'a'*64}}}), '')
        with patch.object(host, 'command', side_effect=command):
            try: host.profile()
            except o.Refused: pass
        self.assertTrue(paths and paths[0].is_file(), 'normal helper points to future candidate')
        self.assertFalse(self.root.joinpath('candidate').exists())

if __name__ == '__main__': unittest.main(verbosity=2)
