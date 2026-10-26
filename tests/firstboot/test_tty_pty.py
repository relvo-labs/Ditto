"""Real non-seekable terminal IO; account tools/state remain explicit doubles.

The child gets real PTY stdin/stdout, as provided by tty-force. Only /dev/tty
opens are redirected to that slave; this does not qualify systemd/VT or PAM.
"""
import contextlib
import fcntl
import functools
import json
import os
from pathlib import Path
import pty
import select
import signal
import subprocess
import sys
import termios
import tempfile
import time
import traceback
import unittest
from unittest import mock

from test_tty_launcher import REPO, load_launcher


RETRY = b'Press Enter for one more setup attempt, or Ctrl-D to stop and return to sign-in: '
STOP = b'Press Enter to return to sign-in: '


class TerminalSession:
    def __init__(self, case, behavior):
        self.case = case
        self.master, slave = pty.openpty()  # A denial must fail, never skip/fake.
        self.report, report_writer = os.pipe()
        self.diagnostic, diagnostic_writer = os.pipe()
        self.pending = b''
        self.transcript = b''
        self.pid = None
        try:
            attrs = termios.tcgetattr(slave)
            case.assertTrue(attrs[3] & termios.ICANON)
            case.assertEqual(attrs[6][termios.VEOF], b'\x04')
            slave_path = os.ttyname(slave)
            self.pid = os.fork()
            if self.pid == 0:
                os.close(self.master)
                os.close(self.report)
                os.close(self.diagnostic)
                os.dup2(slave, 0)
                os.dup2(slave, 1)
                os.dup2(diagnostic_writer, 2)  # Real pipe, like the unit's journal.
                os.close(slave)
                os.close(diagnostic_writer)
                self.child(behavior, slave_path, report_writer)
        finally:
            os.close(slave)
            os.close(report_writer)
            os.close(diagnostic_writer)

    @staticmethod
    def child(behavior, slave_path, report_writer):
        state = {'calls': 0, 'human': behavior == 'existing', 'input': []}
        try:
            launcher = load_launcher()
            real_open = open

            def terminal_open(path, *args, **kwargs):
                return real_open(slave_path if path == '/dev/tty' else path, *args, **kwargs)

            def helper(argv, **kwargs):
                assert argv == [launcher.HELPER, '--tty'], argv
                assert kwargs == {'env': launcher.ENV, 'check': False}, kwargs
                # No redirected stdin/stdout/stderr or user input in argv/env.
                assert os.isatty(0) and os.isatty(1)
                assert os.fstat(0).st_rdev == os.stat(slave_path).st_rdev
                state['calls'] += 1
                if behavior == 'success' or (behavior == 'prefetch' and state['calls'] == 2):
                    os.write(1, 'Fixture helper：你的名字: '.encode('utf-8'))
                    value = b''
                    while not value.endswith(b'\n') and len(value) < 64:
                        assert select.select([0], [], [], 2)[0], 'helper input was consumed or never delivered'
                        part = os.read(0, 1)
                        assert part, 'unexpected helper EOF'
                        value += part
                    assert value == '測試名字\n'.encode('utf-8'), value
                    state['input'].append(value.decode('utf-8'))
                    state['human'] = True
                return subprocess.CompletedProcess(argv, 0 if state['human'] else 1)

            with mock.patch.object(launcher, 'open', side_effect=terminal_open, create=True), mock.patch.object(launcher, 'human_account_exists', side_effect=lambda: state['human']), mock.patch.object(launcher.subprocess, 'run', side_effect=helper):
                state['result'] = launcher.tty_session()
        except BaseException:
            state['error'] = traceback.format_exc()
        os.write(report_writer, json.dumps(state).encode('utf-8'))
        os.close(report_writer)
        os._exit(0)

    def expect(self, text):
        deadline = time.monotonic() + 3
        while text not in self.pending:
            remaining = deadline - time.monotonic()
            self.case.assertGreater(remaining, 0, repr(self.transcript))
            self.case.assertTrue(select.select([self.master], [], [], remaining)[0], repr(self.transcript))
            try:
                part = os.read(self.master, 4096)
            except OSError as error:
                report = os.read(self.report, 65536) if select.select([self.report], [], [], 0)[0] else b''
                self.case.fail(f'terminal closed before {text!r}: {error}; output={self.transcript!r}; report={report!r}')
            self.case.assertTrue(part, repr(self.transcript))
            self.pending += part
            self.transcript += part
        end = self.pending.index(text) + len(text)
        self.pending = self.pending[end:]

    def send(self, value):
        self.case.assertEqual(os.write(self.master, value), len(value))

    def waiting_for_acknowledgement(self):
        self.case.assertEqual(select.select([self.report], [], [], 0)[0], [],
                              'session returned before human acknowledgement')

    def hangup(self):
        os.close(self.master)
        self.master = None

    def finish(self, calls, result=0):
        self.case.assertTrue(select.select([self.report], [], [], 3)[0], 'session did not finish')
        report = json.loads(os.read(self.report, 65536))
        self.case.assertNotIn('error', report, report)
        self.case.assertEqual((report['result'], report['calls']), (result, calls), report)
        _, status = os.waitpid(self.pid, 0)
        self.pid = None
        self.case.assertEqual(os.waitstatus_to_exitcode(status), 0)
        diagnostic = os.read(self.diagnostic, 65536)
        return report, diagnostic

    def close(self):
        if self.pid is not None:
            os.kill(self.pid, signal.SIGKILL)
            os.waitpid(self.pid, 0)
            self.pid = None
        for fd in (self.master, self.report, self.diagnostic):
            if fd is not None:
                os.close(fd)


class TTYRealPTYTests(unittest.TestCase):
    @contextlib.contextmanager
    def session(self, behavior='failure'):
        terminal = TerminalSession(self, behavior)
        try:
            yield terminal
        finally:
            terminal.close()

    def test_success_output_and_utf8_helper_input_on_inherited_stdin(self):
        with self.session('success') as terminal:
            terminal.expect('Fixture helper：你的名字: '.encode('utf-8'))
            terminal.send('測試名字\n'.encode('utf-8'))
            terminal.expect(b'An account was found. Returning to sign-in;')
            report, diagnostic = terminal.finish(1)
            self.assertEqual(report['input'], ['測試名字\n'])
            self.assertEqual(diagnostic, b'')

    def test_retry_enter_leaves_next_line_for_helper(self):
        with self.session('prefetch') as terminal:
            terminal.expect(RETRY)  # Prompt without newline must be flushed.
            terminal.send(b'\n' + '測試名字\n'.encode('utf-8'))
            terminal.expect(b'An account was found. Returning to sign-in;')
            report, _ = terminal.finish(2)
            self.assertEqual(report['input'], ['測試名字\n'])

    def test_three_attempt_bound_and_visible_stop_acknowledgement(self):
        with self.session() as terminal:
            for _ in range(2):
                terminal.expect(RETRY)
                terminal.send(b'\n')
            terminal.expect(b'Setup stopped. Sign-in needs an existing account.')
            terminal.expect(STOP)
            terminal.waiting_for_acknowledgement()
            terminal.send(b'\n')
            terminal.finish(3)

    def test_ctrl_d_eof_at_retry_and_stop_acknowledgement(self):
        with self.session() as terminal:
            terminal.expect(RETRY)
            terminal.send(b'\x04')  # Actual canonical VEOF, not a mocked readline.
            terminal.expect(STOP)
            terminal.waiting_for_acknowledgement()
            terminal.send(b'\x04')
            terminal.finish(1)

    def test_non_ascii_and_invalid_utf8_are_not_retry_confirmation(self):
        for value in ('停止\n'.encode('utf-8'), b'\xff\n'):
            with self.subTest(value=value), self.session() as terminal:
                terminal.expect(RETRY)
                terminal.send(value)
                terminal.expect(STOP)
                terminal.waiting_for_acknowledgement()
                terminal.send(b'\n')
                terminal.finish(1)

    def test_retry_read_is_bounded_without_consuming_future_line(self):
        with self.session() as terminal:
            terminal.expect(RETRY)
            terminal.send(b'x' * 32 + b'\x04')  # Deliver a canonical line with no LF.
            terminal.expect(STOP)
            terminal.waiting_for_acknowledgement()
            terminal.send(b'\n')
            terminal.finish(1)

    def test_terminal_hangup_returns_failure_without_retry(self):
        with self.session() as terminal:
            terminal.expect(RETRY)
            terminal.hangup()
            _, diagnostic = terminal.finish(1, result=1)
            self.assertIn(b'account state could not be confirmed', diagnostic)

    def test_existing_account_skips_helper(self):
        with self.session('existing') as terminal:
            terminal.finish(0)


@functools.cache
def rust_signal_helper():
    """Build the test-only helper offline; denial/build failure must fail the row."""
    result = subprocess.run(
        ['cargo', 'test', '-p', 'ditto-firstboot-account', '--offline', '--locked',
         '--lib', '--no-run', '--message-format=json'],
        cwd=REPO, capture_output=True, text=True, check=True, timeout=120)
    artifacts = [json.loads(line) for line in result.stdout.splitlines()]
    binaries = [item['executable'] for item in artifacts
                if item.get('reason') == 'compiler-artifact'
                and item.get('target', {}).get('name') == 'ditto_firstboot_account'
                and item.get('executable')]
    assert len(binaries) == 1, (binaries, result.stderr)
    return binaries[0]


class SignalTerminalSession(TerminalSession):
    """Production run/wait and /dev/tty, with an exec'ed account helper double.

    This owns a new session and controlling foreground PTY. No account tool,
    root privilege or systemd service is used; markers represent fake state.
    """
    def __init__(self, case, phase):
        self.scratch = tempfile.TemporaryDirectory(prefix='ditto-tty-signals-')
        self.root = Path(self.scratch.name)
        rust_helper = rust_signal_helper() if phase == 'rust-guard' else None
        helper = self.root / 'helper'
        helper.write_text(f'''#!{sys.executable} -I
import os
from pathlib import Path
import signal
import sys
import time
root = Path({str(self.root)!r})
assert sys.argv[1:] == ['--tty']
assert os.tcgetpgrp(0) == os.getpgrp()
# A callable parent handler must reset on exec, never inherit SIG_IGN.
assert signal.getsignal(signal.SIGINT) != signal.SIG_IGN
for sig in (signal.SIGQUIT, signal.SIGTERM, signal.SIGHUP):
    assert signal.getsignal(sig) == signal.SIG_DFL
if {phase!r} == 'rust-guard':
    os.execve({rust_helper!r}, [{rust_helper!r}, '--exact', 'unix::tests::tty_signal_helper_child', '--nocapture'],
              {{'DITTO_220_PTY_ROOT': str(root)}})
with (root / 'calls').open('a') as stream:
    stream.write('call\\n')
received = []
def interrupted(sig, frame):
    received.append(sig)
for sig in (signal.SIGINT, signal.SIGQUIT, signal.SIGTERM, signal.SIGHUP):
    signal.signal(sig, interrupted)
# This Python double only asserts launcher waiting. The rust-guard phase
# above execs a test-only helper using the real Rust SignalGuard.
if {phase!r} == 'after':
    (root / 'created').write_text('committed fixture\\n')
os.write(1, b'Fixture signal helper ready\\n')
deadline = time.monotonic() + 4
while not received:
    assert time.monotonic() < deadline, 'test signal never reached helper'
    time.sleep(0.01)
(root / 'received').write_text(str(received[0]))
# Exceed subprocess.run's KeyboardInterrupt grace period deterministically.
time.sleep(0.6)
if {phase!r} == 'mid':
    (root / 'created').write_text('committed fixture\\n')
(root / 'completed').write_text('finished after signal\\n')
sys.exit(0 if (root / 'created').exists() else 1)
''')
        helper.chmod(0o700)
        try:
            super().__init__(case, phase)
        except BaseException:
            self.scratch.cleanup()
            raise

    def child(self, phase, slave_path, report_writer):
        state = {'reads': []}
        try:
            os.setsid()
            fcntl.ioctl(0, termios.TIOCSCTTY, 0)
            assert os.tcgetpgrp(0) == os.getpgrp() == os.getpid()
            attrs = termios.tcgetattr(0)
            assert attrs[3] & termios.ISIG
            assert attrs[6][termios.VINTR] == b'\x03'
            assert attrs[6][termios.VQUIT] == b'\x1c'
            with open('/dev/tty', 'rb', buffering=0) as tty:
                # /dev/tty is the 5:0 alias, not the slave's device number.
                assert os.tcgetpgrp(tty.fileno()) == os.tcgetpgrp(0)
                assert os.ttyname(0) == slave_path
            launcher = load_launcher()
            original = {sig: signal.getsignal(sig) for sig in
                        (signal.SIGINT, signal.SIGQUIT, signal.SIGTERM, signal.SIGHUP)}

            def account_exists():
                exists = (self.root / 'created').exists()
                state['reads'].append({'human': exists, 'completed': (self.root / 'completed').exists()})
                return exists

            # The real subprocess.run executes the double, preserving fixed
            # argv/env and inherited terminal descriptors. No run/wait mock.
            with mock.patch.object(launcher, 'HELPER', str(self.root / 'helper')), mock.patch.object(launcher, 'human_account_exists', side_effect=account_exists):
                state['result'] = launcher.tty_session()
            state['restored'] = all(signal.getsignal(sig) == old for sig, old in original.items())
        except BaseException:
            state['error'] = traceback.format_exc()
        state['calls'] = len((self.root / 'calls').read_text().splitlines()) if (self.root / 'calls').exists() else 0
        os.write(report_writer, json.dumps(state).encode('utf-8'))
        os.close(report_writer)
        os._exit(0)

    def wait_marker(self, name):
        deadline = time.monotonic() + 3
        while not (self.root / name).exists():
            self.case.assertLess(time.monotonic(), deadline, f'helper did not write {name}')
            time.sleep(0.01)

    def wait_terminated(self, sig):
        deadline = time.monotonic() + 3
        while True:
            pid, status = os.waitpid(self.pid, os.WNOHANG)
            if pid:
                self.pid = None
                self.case.assertEqual(os.waitstatus_to_exitcode(status), -sig)
                return
            self.case.assertLess(time.monotonic(), deadline, 'launcher resisted stop signal')
            time.sleep(0.01)

    def close(self):
        # Group contains only task-owned launcher/helper, even if launcher
        # already died. Always clean children on a failing assertion as well.
        try:
            os.killpg(self.group, signal.SIGKILL)
        except ProcessLookupError:
            pass
        super().close()
        self.scratch.cleanup()


class TTYSignalPTYTests(unittest.TestCase):
    @contextlib.contextmanager
    def session(self, phase):
        terminal = SignalTerminalSession(self, phase)
        terminal.group = terminal.pid
        try:
            terminal.expect(b'Fixture signal helper ready')
            yield terminal
        finally:
            terminal.close()

    def terminal_signal(self, phase, value, sig):
        with self.session(phase) as terminal:
            terminal.send(value)  # Kernel ISIG delivers to the foreground group.
            if phase in ('before', 'no-account'):
                terminal.expect(RETRY)
                terminal.send(b'\x04')
                terminal.expect(STOP)
                terminal.send(b'\n')
            else:
                terminal.expect(b'An account was found. Returning to sign-in;')
            report, diagnostic = terminal.finish(1)
            self.assertEqual((terminal.root / 'received').read_text(), str(sig))
            self.assertTrue((terminal.root / 'completed').exists(), 'helper was killed before completion')
            self.assertTrue(report['restored'], report)
            self.assertEqual(len(report['reads']), 3, report)
            self.assertEqual(report['reads'][-1], {'human': phase in ('mid', 'after', 'rust-guard'), 'completed': True})
            self.assertEqual(diagnostic, b'')

    def test_vintr_before_transaction(self):
        self.terminal_signal('before', b'\x03', signal.SIGINT)

    def test_vintr_mid_transaction_completes_before_account_readback(self):
        self.terminal_signal('mid', b'\x03', signal.SIGINT)

    def test_vintr_helper_without_account_returns_to_bounded_flow(self):
        # This fixture creates no account; it is not transaction rollback evidence.
        self.terminal_signal('no-account', b'\x03', signal.SIGINT)

    def test_vintr_after_commit_waits_for_helper(self):
        self.terminal_signal('after', b'\x03', signal.SIGINT)

    def test_vquit_before_transaction(self):
        self.terminal_signal('before', b'\x1c', signal.SIGQUIT)

    def test_vquit_mid_transaction_waits_for_helper(self):
        self.terminal_signal('mid', b'\x1c', signal.SIGQUIT)

    def test_vquit_with_real_rust_guard_survives_and_returns_to_sign_in(self):
        self.terminal_signal('rust-guard', b'\x1c', signal.SIGQUIT)

    def test_vquit_after_commit_waits_for_helper(self):
        self.terminal_signal('after', b'\x1c', signal.SIGQUIT)

    def test_vintr_at_retry_still_stops(self):
        with self.session('before') as terminal:
            # First VINTR lets the helper finish without creating an account;
            # the second tests the restored launcher handler at retry.
            terminal.send(b'\x03')
            terminal.expect(RETRY)
            terminal.send(b'\x03')
            report, diagnostic = terminal.finish(1, result=1)
            self.assertTrue(report['restored'], report)
            self.assertIn(b'account state could not be confirmed', diagnostic)

    def test_systemd_group_stop_signals_leave_launcher_killable(self):
        for sig in (signal.SIGTERM, signal.SIGHUP):
            for phase in ('before', 'mid', 'after'):
                with self.subTest(signal=sig, phase=phase), self.session(phase) as terminal:
                    os.killpg(terminal.group, sig)  # control-group analogue, no systemd claim.
                    terminal.wait_terminated(sig)
                    terminal.wait_marker('completed')
                    self.assertEqual((terminal.root / 'received').read_text(), str(sig))
                    self.assertEqual((terminal.root / 'created').exists(), phase != 'before')


if __name__ == '__main__':
    unittest.main()
