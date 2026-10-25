"""Fixed handoff graph, identity and cleanup invariants (no service starts)."""
import configparser
import os
from pathlib import Path
import unittest

REPO = Path(os.environ.get('DITTO_FIRSTBOOT_TEST_ROOT', Path(__file__).resolve().parents[2]))
UNITS = REPO / 'packaging/distro/first-boot/units'


def unit(name):
    conf = configparser.ConfigParser(interpolation=None)
    conf.read(UNITS / name)
    return conf


class TTYUnitTests(unittest.TestCase):
    def test_vt_order_cleanup(self):
        conf = unit('ditto-firstboot-account-tty.service')
        self.assertEqual(conf['Service']['ExecStart'], '/usr/lib/ditto/ditto-firstboot-tty --tty-session')
        self.assertEqual(conf['Service']['User'], 'root')
        self.assertEqual(conf['Service']['StandardInput'], 'tty-force')
        self.assertEqual(conf['Service']['TTYPath'], '/dev/tty1')
        self.assertEqual(conf['Service']['PrivateDevices'], 'no')
        for field in ('TTYReset', 'TTYVHangup', 'SendSIGHUP'):
            self.assertEqual(conf['Service'][field], 'yes')
        self.assertEqual(conf['Service']['KillMode'], 'control-group')
        self.assertEqual(conf['Service']['Restart'], 'no')
        self.assertEqual(set(conf['Unit']['Conflicts'].split()), {'greetd.service', 'getty@tty1.service'})
        self.assertLessEqual({'greetd.service', 'getty@tty1.service'}, set(conf['Unit']['After'].split()))
        self.assertEqual(conf['Unit']['OnSuccess'], 'greetd.service')
        self.assertEqual(conf['Unit']['OnFailure'], 'greetd.service')
        self.assertEqual(set(conf['Service']['CapabilityBoundingSet'].split()), {'CAP_CHOWN', 'CAP_DAC_OVERRIDE', 'CAP_FOWNER'})
        self.assertEqual(conf['Unit']['Requires'], 'ditto-firstboot-tty-prepare.service')

    def test_recovery_failure_allows_login_and_explanation(self):
        tty = unit('ditto-firstboot-account-tty.service')
        recover = unit('ditto-firstboot-account-recover.service')
        self.assertEqual(tty['Unit']['Wants'], 'ditto-firstboot-account-recover.service')
        self.assertNotIn('ditto-firstboot-account-recover.service', tty['Unit'].get('Requires', '').split())
        self.assertNotIn('ConditionPathExists', tty['Unit'])
        self.assertEqual(set(recover['Install']['WantedBy'].split()), {'greetd.service', 'sysinit.target'})
        self.assertNotIn('RequiredBy', recover['Install'])
        self.assertIn('greetd.service', recover['Unit']['Before'].split())

    def test_vt_capability_is_separate_from_helper(self):
        prepare = unit('ditto-firstboot-tty-prepare.service')
        self.assertEqual(prepare['Service']['ExecStart'], '/usr/lib/ditto/ditto-firstboot-tty --prepare')
        self.assertEqual(prepare['Service']['CapabilityBoundingSet'], 'CAP_SYS_TTY_CONFIG')
        self.assertEqual(prepare['Service']['RemainAfterExit'], 'yes')
        self.assertEqual(prepare['Service']['TTYPath'], '/dev/tty1')
        self.assertEqual(prepare['Unit']['OnFailure'], 'greetd.service')
        self.assertEqual(set(prepare['Unit']['Conflicts'].split()), {'greetd.service', 'getty@tty1.service'})
        self.assertLessEqual({'greetd.service', 'getty@tty1.service'}, set(prepare['Unit']['After'].split()))
        self.assertNotIn('Requires', prepare['Unit'])

    def test_dispatch_cannot_stop_login_before_auth(self):
        dispatch = unit('ditto-firstboot-tty-dispatch.service')
        self.assertEqual(dispatch['Service']['User'], 'root')
        self.assertEqual(dispatch['Service']['ExecStart'], '/usr/lib/ditto/ditto-firstboot-tty --dispatch')
        self.assertEqual(dispatch['Service']['NoNewPrivileges'], 'yes')
        self.assertEqual(dispatch['Service']['CapabilityBoundingSet'], '')
        self.assertEqual(dispatch['Service']['ReadWritePaths'], '/run/ditto')
        self.assertNotIn('Conflicts', dispatch['Unit'])
        self.assertNotIn('After', dispatch['Unit'])  # No wait on the service being stopped.
        self.assertNotIn('ExecStartPre', dispatch['Service'])

    def test_handoff_socket_fixed_identity(self):
        conf = unit('ditto-firstboot-tty-dispatch.socket')
        self.assertEqual(conf['Socket']['ListenStream'], '/run/ditto/firstboot-tty.sock')
        self.assertEqual(conf['Socket']['SocketUser'], 'root')
        self.assertEqual(conf['Socket']['SocketGroup'], '_greetd')
        self.assertEqual(conf['Socket']['SocketMode'], '0660')
        self.assertEqual(conf['Socket']['Accept'], 'no')
        self.assertEqual(conf['Socket']['RemoveOnStop'], 'yes')
        self.assertEqual(conf['Install']['WantedBy'], 'sockets.target')

    def test_ordering_graph_is_acyclic(self):
        # Static ordering including the relevant default systemd edges. Runtime
        # conflict-stop and OnSuccess transitions still need actual systemd VM.
        edges = {('sysinit.target', 'basic.target'), ('sockets.target', 'basic.target'),
                 ('systemd-tmpfiles-setup.service', 'sysinit.target')}
        for path in UNITS.iterdir():
            conf = unit(path.name)
            for before in conf['Unit'].get('Before', '').split():
                edges.add((path.name, before))
            for after in conf['Unit'].get('After', '').split():
                edges.add((after, path.name))
            if conf['Unit'].get('DefaultDependencies', 'yes') != 'no':
                if path.suffix == '.service':
                    edges.add(('basic.target', path.name))
                elif path.suffix == '.socket':
                    edges.add((path.name, 'sockets.target'))
        nodes = {n for pair in edges for n in pair}
        while nodes:
            ready = {n for n in nodes if not any(b == n and a in nodes for a, b in edges)}
            self.assertTrue(ready, 'ordering cycle: ' + repr(sorted(nodes)))
            nodes -= ready

    def test_root_latch_cannot_be_cleared_by_greeter(self):
        source = (REPO / 'packaging/distro/first-boot/ditto-firstboot-tty').read_text()
        self.assertIn("USED = Path('/run/ditto/firstboot-tty-used')", source)
        self.assertIn('os.O_EXCL | os.O_NOFOLLOW', source)
        self.assertIn('mode.st_uid != 0 or mode.st_mode & 0o022', source)
        self.assertNotIn('USED.unlink', source)
        self.assertNotIn('USED = os.environ', source)
        # Existing runtime directory stays root owned and not greeter writable.
        tmpfiles = (REPO / 'packaging/distro/first-boot/tmpfiles.d/ditto-firstboot.conf').read_text()
        self.assertIn('d /run/ditto 0755 root root -', tmpfiles)

    def test_helper_trust_boundary_unchanged(self):
        source = (REPO / 'crates/ditto-firstboot-account/src/main.rs').read_text()
        self.assertLess(source.index('libc::geteuid()'), source.index('args_os()'))
        self.assertIn('libc::geteuid() } != 0', source)
        wrapper = (REPO / 'packaging/distro/first-boot/ditto-greeter').read_text()
        self.assertNotIn('/usr/lib/ditto/ditto-firstboot-account --tty', wrapper)
        self.assertIn('/usr/lib/ditto/ditto-firstboot-tty --request', wrapper)
        self.assertNotIn('sudo ', wrapper)


if __name__ == '__main__':
    unittest.main()
