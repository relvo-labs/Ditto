"""Real non-seekable terminal IO; account tools/state remain explicit doubles.

The child gets real PTY stdin/stdout, as provided by tty-force. Only /dev/tty
opens are redirected to that slave; this does not qualify systemd/VT or PAM.
"""
import contextlib
import json
import os
import pty
import select
import signal
import subprocess
import termios
import time
import traceback
import unittest
from unittest import mock

from test_tty_launcher import load_launcher


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


if __name__ == '__main__':
    unittest.main()
