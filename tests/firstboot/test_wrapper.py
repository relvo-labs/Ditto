"""Run the real wrapper logic with fixed image paths relocated into fixtures.
No host account/DRM/session writes. The command doubles record only stage names.
"""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]
WRAPPER = REPO / 'packaging/distro/first-boot/ditto-greeter'


class WrapperTests(unittest.TestCase):
    def run_wrapper(self, accounts='', drm=False, gpu=1, software=1, getent_status=0, defs=None):
        with tempfile.TemporaryDirectory(prefix='ditto-212-wrapper-') as temp:
            root = Path(temp)
            commands = root / 'bin'
            commands.mkdir()
            calls = root / 'calls'
            calls.touch()
            def executable(name, text):
                path = commands / name
                path.write_text('#!/bin/bash\n' + text)
                path.chmod(0o755)
                return path
            executable('getent', 'printf "%s\\n" "$FIXTURE_ACCOUNTS"\nexit "$FIXTURE_GETENT_STATUS"\n')
            executable('agreety', '[[ "$*" == "--cmd /usr/local/libexec/ditto-image-session" ]] || exit 77\necho login >> "$FIXTURE_CALLS"\n')
            executable('account', '[[ "$*" == --tty ]] || exit 78\necho tty >> "$FIXTURE_CALLS"\n')
            executable('dbus-run-session', '''
[[ "$1" == -- && "$3" == --graphical ]] || exit 79
if [[ ${WLR_RENDERER:-} == pixman ]]; then
    [[ $QT_QUICK_BACKEND == software ]] || exit 80
    echo software >> "$FIXTURE_CALLS"
    exit "$FIXTURE_SOFTWARE"
fi
echo gpu >> "$FIXTURE_CALLS"
exit "$FIXTURE_GPU"
''')
            login_defs = root / 'login.defs'
            login_defs.write_text(defs if defs is not None else 'UID_MIN 2000\nUID_MAX 4000\n')
            device = root / ('drm/card7-HDMI-A-1/device' if drm == 'connector' else 'drm/card7/device')
            if drm:
                device.mkdir(parents=True)
            script = WRAPPER.read_text().replace('/usr/sbin/agreety', str(commands / 'agreety'))
            script = script.replace('/usr/lib/ditto/ditto-firstboot-account', str(commands / 'account'))
            script = script.replace('/etc/login.defs', str(login_defs)).replace('/sys/class/drm/', str(root / 'drm') + '/')
            wrapper = root / 'wrapper'
            wrapper.write_text(script)
            env = {**os.environ, 'PATH': str(commands) + ':' + os.environ['PATH'],
                   'FIXTURE_ACCOUNTS': accounts, 'FIXTURE_GETENT_STATUS': str(getent_status),
                   'FIXTURE_GPU': str(gpu), 'FIXTURE_SOFTWARE': str(software), 'FIXTURE_CALLS': str(calls)}
            result = subprocess.run(['bash', str(wrapper)], env=env, text=True, capture_output=True, timeout=10)
            return result.returncode, calls.read_text().splitlines(), result.stderr

    def test_uid_bounds_and_existing_account(self):
        for uid, expected in ((1999, ['tty', 'login']), (2000, ['login']), (4000, ['login']), (4001, ['tty', 'login'])):
            with self.subTest(uid=uid):
                code, calls, error = self.run_wrapper(accounts=f'fixture:x:{uid}:{uid}::/fixture:/bin/bash')
                self.assertEqual((code, calls), (0, expected), error)

    def test_no_drm_goes_straight_to_text(self):
        for drm in (False, 'connector'):
            code, calls, error = self.run_wrapper(drm=drm)
            self.assertEqual((code, calls), (0, ['tty', 'login']), error)

    def test_gpu_software_and_text_are_bounded(self):
        for gpu, software, expected in ((0, 1, ['gpu']), (1, 0, ['gpu', 'software']), (1, 1, ['gpu', 'software', 'tty', 'login'])):
            with self.subTest(gpu=gpu, software=software):
                code, calls, error = self.run_wrapper(drm=True, gpu=gpu, software=software)
                self.assertEqual((code, calls), (0, expected), error)

    def test_account_lookup_fails_closed(self):
        for options in ({'getent_status': 2}, {'defs': 'UID_MIN broken\nUID_MAX 4000\n'}, {'defs': 'UID_MIN 5000\nUID_MAX 4000\n'}):
            code, calls, error = self.run_wrapper(**options)
            self.assertEqual((code, calls), (2, []), error)


if __name__ == '__main__':
    unittest.main()
