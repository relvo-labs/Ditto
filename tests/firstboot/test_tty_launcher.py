"""Policy/sequence controls in scratch roots; not real root/systemd/VT acceptance."""
import contextlib
import errno
import importlib.machinery
import importlib.util
import io
import os
from pathlib import Path
import socket
import stat
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

REPO = Path(os.environ.get('DITTO_FIRSTBOOT_TEST_ROOT', Path(__file__).resolve().parents[2]))
SCRIPT = REPO / 'packaging/distro/first-boot/ditto-firstboot-tty'


def load_launcher():
    loader = importlib.machinery.SourceFileLoader('tty_launcher', str(SCRIPT))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


class Connection:
    """Deterministic wire/credential fixture, not kernel peer authentication.

    Runner policy blocks AF_UNIX send/getpeercred. Real peer denial/acceptance
    must also run through the activated services in the disposable VM.
    """
    def __init__(self, frame):
        self.input = io.BytesIO(frame)
        self.output = b''

    def settimeout(self, value):
        self.timeout = value

    def getsockopt(self, level, option, size):
        assert (level, option, size) == (socket.SOL_SOCKET, socket.SO_PEERCRED, 12)
        import struct
        return struct.pack('3i', os.getpid(), os.getuid(), os.getgid())

    def recv(self, size):
        return self.input.read(size)

    def sendall(self, value):
        self.output += value


class TTYLauncherTests(unittest.TestCase):
    def setUp(self):
        self.launcher = load_launcher()

    def dispatch(self, frame=b'tty\n', human=False, replay=False, uid=None, unrelated=False):
        m = self.launcher
        # Identity fixture uses this runner's actual non-root identity. Kernel
        # authentication and root/VT effects are deliberately not claimed here.
        server = Connection(frame)
        with contextlib.ExitStack() as stack:
            stack.enter_context(mock.patch.object(m.pwd, 'getpwnam', return_value=SimpleNamespace(pw_uid=os.getuid() if uid is None else uid)))
            stack.enter_context(mock.patch.object(m, 'fixed_output', return_value=str(os.getppid())))
            if unrelated:
                stack.enter_context(mock.patch.object(m, 'process_parent', return_value=1))
            account = stack.enter_context(mock.patch.object(m, 'human_account_exists', side_effect=human if isinstance(human, Exception) else None, return_value=human))
            stack.enter_context(mock.patch.object(m.os.path, 'lexists', return_value=replay))
            claim = stack.enter_context(mock.patch.object(m, 'claim_handoff'))
            effect = stack.enter_context(mock.patch.object(m.subprocess, 'run'))
            m.dispatch(server)
            reply = server.output
            return reply, account.call_count, claim.call_count, effect.call_args_list

    def test_dispatch_trusted(self):
        reply, reads, claims, effects = self.dispatch()
        self.assertEqual((reply, reads, claims), (b'accepted\n', 1, 1))
        self.assertEqual(effects[0].args[0], ['/usr/bin/systemctl', '--no-block', 'start', 'ditto-firstboot-account-tty.service'])
        self.assertEqual(effects[0].kwargs['env'], self.launcher.ENV)

    def test_dispatch_wrong_uid(self):
        self.assertEqual(self.dispatch(uid=os.getuid() + 1), (b'denied\n', 0, 0, []))

    def test_dispatch_unrelated_peer(self):
        self.assertEqual(self.dispatch(unrelated=True), (b'denied\n', 0, 0, []))

    def test_dispatch_malformed(self):
        for frame in (b'', b'tty', b'tty\nX', b'/bin/sh\n', b'tty\n\x00', b'--tty\n'):
            with self.subTest(frame=frame):
                self.assertEqual(self.dispatch(frame), (b'denied\n', 0, 0, []))

    def test_dispatch_existing(self):
        self.assertEqual(self.dispatch(human=True), (b'login\n', 1, 0, []))

    def test_dispatch_lookup_failure(self):
        self.assertEqual(self.dispatch(human=ValueError('fixture lookup failed')), (b'login\n', 1, 0, []))

    def test_dispatch_replay(self):
        self.assertEqual(self.dispatch(replay=True), (b'login\n', 1, 0, []))

    def test_dispatch_effect_failure_retains_claim(self):
        m = self.launcher
        server = Connection(b'tty\n')
        with mock.patch.object(m, 'trusted_peer', return_value=True), mock.patch.object(m, 'human_account_exists', return_value=False), mock.patch.object(m.os.path, 'lexists', return_value=False), mock.patch.object(m, 'claim_handoff') as claim, mock.patch.object(m.subprocess, 'run', side_effect=OSError('fixture')):
            m.dispatch(server)
            self.assertEqual(server.output, b'login\n')
            claim.assert_called_once()

    def test_claim_exclusive_and_unsafe_parent(self):
        m = self.launcher
        with tempfile.TemporaryDirectory(prefix='ditto-tty-latch-') as temp:
            target = Path(temp) / 'used'
            safe = SimpleNamespace(st_mode=stat.S_IFDIR | 0o755, st_uid=0)
            with mock.patch.object(m, 'USED', target), mock.patch.object(Path, 'lstat', return_value=safe):
                m.claim_handoff()
                self.assertEqual(target.read_bytes(), b'tty1\n')
                with self.assertRaises(FileExistsError):
                    m.claim_handoff()
            target.unlink()
            unsafe = SimpleNamespace(st_mode=stat.S_IFDIR | 0o777, st_uid=0)
            with mock.patch.object(m, 'USED', target), mock.patch.object(Path, 'lstat', return_value=unsafe):
                with self.assertRaises(ValueError):
                    m.claim_handoff()
                self.assertFalse(target.exists())

    def test_source_defined_account_preflight(self):
        m = self.launcher
        root = 'root:x:0:0::/root:/bin/bash\n'
        human = 'alice:x:1000:1000::/home/alice:/bin/bash\n'
        for local, nss, expected in ((root, root, False), (root + human, root, True), (root, root + human, True)):
            with self.subTest(local=local, nss=nss), mock.patch.object(Path, 'read_text', side_effect=['UID_MIN 1000\nUID_MAX 60000\n', local]), mock.patch.object(m, 'fixed_output', return_value=nss):
                self.assertEqual(m.human_account_exists(), expected)
        for defs, passwd in (('UID_MIN 0\nUID_MAX 60000', root), ('UID_MIN 1000\nUID_MIN 1000\nUID_MAX 60000', root), ('UID_MIN x\nUID_MAX 60000', root), ('UID_MIN 1000\nUID_MAX 60000', 'malformed')):
            with self.subTest(defs=defs, passwd=passwd), mock.patch.object(Path, 'read_text', side_effect=[defs, passwd]), mock.patch.object(m, 'fixed_output', return_value=root), self.assertRaises((ValueError, KeyError)):
                m.human_account_exists()

    def session(self, answers='', human=False, helper=None):
        m = self.launcher
        reader = io.BytesIO(answers.encode('utf-8'))
        tty = io.StringIO()
        # Separate queues for policy tests only; test_tty_pty.py covers real IO.
        def terminal_open(path, mode, **kwargs):
            self.assertEqual(path, '/dev/tty')
            return contextlib.nullcontext(reader if mode == 'rb' else tty)
        reads = mock.Mock(side_effect=human) if isinstance(human, list) else mock.Mock(return_value=human)
        with mock.patch.object(m, 'human_account_exists', reads), mock.patch.object(m, 'retire_greeter'), mock.patch.object(m, 'activate_tty1') as vt, mock.patch('builtins.open', side_effect=terminal_open), mock.patch.object(m.subprocess, 'run', side_effect=helper) as run, contextlib.redirect_stderr(io.StringIO()) as output:
            result = m.tty_session()
            return result, run.call_args_list, vt.call_count, tty.getvalue(), output.getvalue()

    def test_tty_existing_skips_helper(self):
        result, calls, vt, _, _ = self.session(human=True)
        self.assertEqual((result, calls, vt), (0, [], 0))

    def test_tty_success_returns_login(self):
        result, calls, vt, text, _ = self.session(human=[False, False, True])
        self.assertEqual((result, len(calls), vt), (0, 1, 0))
        self.assertEqual(calls[0].args[0], ['/usr/lib/ditto/ditto-firstboot-account', '--tty'])
        self.assertIn('Returning to sign-in', text)

    def test_tty_invalid_retry_bound(self):
        # A duplex tty's input and output have separate queues. Mock the
        # explicit retry reads, not helper validation or account creation.
        m = self.launcher
        tty = mock.MagicMock()
        tty.__enter__.return_value = tty
        tty.readline.return_value = b'\n'
        with mock.patch.object(m, 'human_account_exists', return_value=False), mock.patch.object(m, 'retire_greeter'), mock.patch.object(m, 'activate_tty1'), mock.patch('builtins.open', return_value=tty), mock.patch.object(m.subprocess, 'run') as run:
            self.assertEqual(m.tty_session(), 0)
            self.assertEqual(run.call_count, 3)
            self.assertEqual(tty.readline.call_count, 3)  # Two retries, then acknowledge stop.
            self.assertTrue(any('Setup stopped.' in c.args[0] for c in tty.write.call_args_list))

    def test_tty_eof(self):
        # Empty policy-fixture input yields EOF independently of output writes.
        result, calls, _, text, _ = self.session()
        self.assertEqual((result, len(calls)), (0, 1))
        self.assertIn('Setup stopped.', text)

    def test_tty_interrupted(self):
        result, calls, _, _, text = self.session(helper=KeyboardInterrupt())
        self.assertEqual((result, len(calls)), (1, 1))
        self.assertIn('could not be confirmed', text)

    def test_tty_ambiguous_recovery(self):
        result, calls, _, text, _ = self.session(helper=lambda *a, **k: subprocess.CompletedProcess(a, 1))
        self.assertEqual((result, len(calls)), (0, 1))
        self.assertIn('do not delete pending records', text)

    def test_request_fixed_frame_and_fragmented_ack(self):
        m = self.launcher
        client = mock.MagicMock()
        client.__enter__.return_value = client
        client.recv.side_effect = [b'acc', b'epted\n']
        with mock.patch.object(m.socket, 'socket', return_value=client), mock.patch.object(m.signal, 'alarm') as alarm, mock.patch.object(m.signal, 'pause') as pause:
            self.assertEqual(m.request(), 1)  # Normally killed by the queued stop.
            client.connect.assert_called_once_with('/run/ditto/firstboot-tty.sock')
            client.sendall.assert_called_once_with(b'tty\n')
            client.shutdown.assert_called_once_with(socket.SHUT_WR)
            alarm.assert_called_once_with(15)
            pause.assert_called_once()

    def test_activation_rejects_untrusted_descriptor_metadata(self):
        m = self.launcher
        with mock.patch.dict(m.os.environ, {'LISTEN_PID': str(os.getpid() + 1), 'LISTEN_FDS': '1'}), mock.patch.object(m.socket, 'socket') as opened:
            with self.assertRaises(ValueError):
                m.activated_listener()
            opened.assert_not_called()

    def test_root_uid_cannot_be_greeter_cleanup_target(self):
        m = self.launcher
        with mock.patch.object(m.pwd, 'getpwnam', return_value=SimpleNamespace(pw_uid=0)), mock.patch.object(m.subprocess, 'run') as command:
            with self.assertRaises(ValueError):
                m.retire_greeter()
            command.assert_not_called()

    def test_retire_greeter_including_logind_scope(self):
        m = self.launcher
        with mock.patch.object(m.pwd, 'getpwnam', return_value=SimpleNamespace(pw_uid=999)), mock.patch.object(m.subprocess, 'run') as command, mock.patch.object(Path, 'iterdir', return_value=[Path('/proc/42')]), mock.patch.object(Path, 'read_text', side_effect=['Uid: 999 999 999 999\nState: S (sleeping)\n', 'Uid: 999 999 999 999\nState: Z (zombie)\n']), mock.patch.object(m.time, 'sleep') as wait:
            m.retire_greeter()
            self.assertEqual(command.call_args.args[0], ['/usr/bin/loginctl', 'terminate-user', '_greetd'])
            wait.assert_called_once_with(0.05)

    def test_lingering_greeter_refuses_vt_and_helper(self):
        m = self.launcher
        with mock.patch.object(m.os, 'geteuid', return_value=0), mock.patch.object(m, 'retire_greeter', side_effect=ValueError('still alive')), mock.patch.object(m, 'activate_tty1') as vt, mock.patch.object(m.subprocess, 'run') as run:
            with self.assertRaises(ValueError):
                m.main(['--prepare'])
            vt.assert_not_called()
            run.assert_not_called()

    def test_retire_greeter_vanished_status_reads_continue_scanning(self):
        m = self.launcher
        # Unlike OSError(errno.ESRCH, ...), this subclass is not automatically
        # converted by Python into ProcessLookupError.
        class StatusError(OSError):
            pass
        for error in (FileNotFoundError(), ProcessLookupError(),
                      StatusError(errno.ESRCH, 'fixture process reaped')):
            with self.subTest(error=type(error).__name__), mock.patch.object(m, 'greeter_uid', return_value=999), mock.patch.object(m.subprocess, 'run'), mock.patch.object(Path, 'iterdir', return_value=[Path('/proc/41'), Path('/proc/42')]), mock.patch.object(Path, 'read_text', side_effect=[error, 'Uid: 1000 1000 1000 1000\nState: S\n']) as read:
                m.retire_greeter()
                self.assertEqual(read.call_count, 2)

    def test_retire_live_greeter_keeps_five_second_deadline(self):
        m = self.launcher
        with mock.patch.object(m, 'greeter_uid', return_value=999), mock.patch.object(m.subprocess, 'run'), mock.patch.object(Path, 'iterdir', return_value=[Path('/proc/42')]), mock.patch.object(Path, 'read_text', return_value='Uid: 999 999 999 999\nState: S\n'), mock.patch.object(m.time, 'monotonic', side_effect=[10, 14.99, 15]), mock.patch.object(m.time, 'sleep') as wait:
            with self.assertRaisesRegex(ValueError, 'greeter still running'):
                m.retire_greeter()
            wait.assert_called_once_with(0.05)

    def test_retire_greeter_unrelated_failures_propagate(self):
        m = self.launcher
        for error in (PermissionError(errno.EACCES, 'fixture denied'),
                      OSError(errno.EIO, 'fixture IO failure')):
            with self.subTest(error=error), mock.patch.object(m, 'greeter_uid', return_value=999), mock.patch.object(m.subprocess, 'run'), mock.patch.object(Path, 'iterdir', return_value=[Path('/proc/42')]), mock.patch.object(Path, 'read_text', side_effect=error), self.assertRaises(type(error)):
                m.retire_greeter()
        with mock.patch.object(m, 'greeter_uid', return_value=999), mock.patch.object(m.subprocess, 'run'), mock.patch.object(Path, 'iterdir', side_effect=ProcessLookupError()), self.assertRaises(ProcessLookupError):
            m.retire_greeter()  # Only a vanished status entry is safe to skip.

    def test_prepare_retires_session_before_vt(self):
        m = self.launcher
        order = []
        with mock.patch.object(m.os, 'geteuid', return_value=0), mock.patch.object(m, 'retire_greeter', side_effect=lambda: order.append('retire')), mock.patch.object(m, 'activate_tty1', side_effect=lambda: order.append('activate')):
            self.assertEqual(m.main(['--prepare']), 0)
            self.assertEqual(order, ['retire', 'activate'])

    def test_activate_rejects_non_tty_before_ioctl(self):
        with mock.patch.object(self.launcher.os, 'isatty', return_value=False), mock.patch.object(self.launcher.os, 'open') as opened:
            with self.assertRaises(ValueError):
                self.launcher.activate_tty1()
            opened.assert_not_called()

    def test_activate_fixed_vt_and_deadline_cleanup(self):
        m = self.launcher
        with mock.patch.object(m.os, 'isatty', return_value=True), mock.patch.object(m.os, 'fstat', return_value=SimpleNamespace(st_rdev=os.makedev(4, 1))), mock.patch.object(m.os, 'tcgetpgrp', return_value=123), mock.patch.object(m.os, 'getpgrp', return_value=123), mock.patch.object(m.os, 'open', return_value=42), mock.patch.object(m.os, 'close') as close, mock.patch.object(m.fcntl, 'ioctl') as ioctl, mock.patch.object(m.signal, 'signal', return_value=0), mock.patch.object(m.signal, 'alarm') as alarm:
            m.activate_tty1()
            self.assertEqual(ioctl.call_args_list, [mock.call(42, 0x5606, 1), mock.call(42, 0x5607, 1)])
            self.assertEqual(alarm.call_args_list, [mock.call(5), mock.call(0)])
            close.assert_called_once_with(42)

    def test_cli_denies_nonroot_and_args(self):
        self.assertNotEqual(os.geteuid(), 0, 'this test must run unprivileged')
        for args in (['--dispatch'], ['--tty-session'], ['--prepare'], ['--dispatch', '/bin/sh'], ['--request', '/arbitrary'], []):
            result = subprocess.run([sys.executable, '-I', str(SCRIPT), *args], capture_output=True, timeout=5)
            self.assertEqual(result.returncode, 77, result.stderr)
        with mock.patch.object(self.launcher.os, 'geteuid', return_value=0):
            self.assertEqual(self.launcher.main(['--tty-session', '/arbitrary']), 77)


if __name__ == '__main__':
    unittest.main()
