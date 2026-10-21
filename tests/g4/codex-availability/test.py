#!/usr/bin/env python3
"""Development regression: execute installer selection and session env blocks.

No install, network, systemd, compositor or real Codex is invoked.
"""
import hashlib
import json
import os
import re
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]


class CodexAvailability(unittest.TestCase):
    def check_selection(self, binary, expected, abi=8, development=True):
        with tempfile.TemporaryDirectory(prefix="codex-availability-") as directory:
            scratch = Path(directory)
            pin = scratch / "tools/codex/pin.json"
            pin.parent.mkdir(parents=True)
            pin_data = json.loads((ROOT / 'tools/codex/pin.json').read_text())
            pin_data.update(version="fixture", sha256=hashlib.sha256(b"pinned fixture").hexdigest())
            pin.write_text(json.dumps(pin_data))
            probe = scratch / "target/release/ditto-confine"
            probe.parent.mkdir(parents=True)
            probe.write_text('#!/bin/sh\n[ "$1" = --landlock-abi ] || exit 64\nprintf "%s\\n" "$FIXTURE_LANDLOCK_ABI"\n')
            probe.chmod(0o755)
            codex = scratch / "codex"
            if binary is not None:
                codex.write_bytes(binary)
            installer = (ROOT / "packaging/reference-image/install-session.sh").read_text()
            selection = installer[installer.index('codex="$(readlink'):installer.index('bash "$workspace/scripts/build-builtin-packages.sh"')]
            options = installer[installer.index('development=""'):installer.index("# ditto-core's crate")]
            fixture_here = scratch / 'reference-image'
            fixture_here.mkdir()
            (fixture_here / 'preflight.sh').write_text('#!/bin/sh\nprintf checked > "$FIXTURE_PREFLIGHT"\n')
            session = (ROOT / "packaging/reference-image/session/ditto-session").read_text()
            env_block = session[session.rindex('{\n', 0, session.index('  echo "WAYFIRE_SOCKET=')):session.index('# D-Bus-activated services')]
            # Render exactly the installer-owned status placeholder, then run
            # the production env-file block without launching a desktop.
            script = options + '\n' + selection + '\n{\n' + env_block.replace('@DITTO_CODEX_STATUS@', '${agent_backend_status}').replace('@DITTO_CODEX_LANDLOCK_ABI@', '${landlock_abi}') + '\n} 2>"$session_notice"'
            result = subprocess.run(['bash', '-eu', '-c', script, 'fixture-installer'] + (['--development'] if development else []), env={**os.environ,
                'workspace': directory, 'here': str(fixture_here), 'FIXTURE_PREFLIGHT': str(scratch / 'preflight-ran'),
                'DITTO_CODEX_BINARY': str(codex), 'FIXTURE_LANDLOCK_ABI': str(abi),
                'WAYFIRE_SOCKET': 'fixture', 'XDG_CONFIG_DIRS': str(fixture_here / 'session/xdg') + ':/etc/xdg', 'variant': '', 'session_env': str(scratch / 'session.env'), 'session_notice': str(scratch / 'notice')},
                text=True, capture_output=True, check=True)
            self.assertEqual((scratch / 'preflight-ran').exists(), not development)
            self.assertIn('DITTO_CODEX_STATUS=' + expected, (scratch / 'session.env').read_text())
            self.assertIn('DITTO_CODEX_LANDLOCK_ABI=' + str(abi), (scratch / 'session.env').read_text())
            self.assertIn('XDG_CONFIG_DIRS=' + str(fixture_here / 'session/xdg') + ':/etc/xdg', (scratch / 'session.env').read_text())
            if abi < 6:
                self.assertIn('WARNING', result.stderr)
                self.assertIn('Landlock ABI', result.stderr)
                self.assertIn('upgrade', result.stderr)
                self.assertIn('API', result.stderr)
            if expected == 'isolation_unavailable':
                self.assertIn('pinned fixture', result.stderr)
                notice = (scratch / 'notice').read_text()
                self.assertIn('安全隔離', notice)
                self.assertIn('系統核心', notice)
                self.assertNotIn('安裝程式', notice)
                self.assertIn('API 金鑰', notice)
            elif expected == 'backend_unsupported':
                with self.subTest(check='help-path'):
                    paths = re.findall(r'\S+README\.md', result.stderr)
                    self.assertEqual(len(paths), 1, result.stderr)
                    document = ROOT / Path(paths[0]).relative_to(scratch)
                    self.assertTrue(document.is_file(), result.stderr)
                    for step in ['tools/codex/pin.json', 'sha256sum', 'DITTO_CODEX_BINARY']:
                        self.assertTrue(step in document.read_text(), f"missing Codex step: {step}")
                with self.subTest(check='installer-language-and-next-step'):
                    self.assertTrue(result.stderr.isascii(), result.stderr)
                    self.assertIn('API', result.stderr)
                    self.assertIn('fixture', result.stderr)
                    self.assertIn('rerun', result.stderr)
                with self.subTest(check='session-notice'):
                    notice = (scratch / 'notice').read_text()
                    self.assertIn('Codex 訂閱無法使用', notice)
                    self.assertIn('安裝程式', notice)
                    self.assertIn('API 金鑰', notice)
                    self.assertIn('桌面仍可照常操作', notice)
            else:
                self.assertIn('pinned fixture', result.stderr)
                self.assertTrue(result.stderr.isascii(), result.stderr)
                self.assertEqual((scratch / 'notice').read_text(), '')

    def test_low_or_unavailable_landlock(self):
        for abi in [4, 5, -1]:
            with self.subTest(abi=abi):
                self.check_selection(b'pinned fixture', 'isolation_unavailable', abi)

    def test_missing_binary_with_old_kernel_still_warns(self):
        self.check_selection(None, 'backend_unsupported', 4)

    def test_minimum_landlock(self):
        self.check_selection(b'pinned fixture', 'available', 6, development=False)

    def test_readme_download_matches_pin(self):
        pin = json.loads((ROOT / 'tools/codex/pin.json').read_text())
        readme = (ROOT / 'packaging/reference-image/README.md').read_text()
        self.assertEqual(pin.get('url'), f"https://github.com/openai/codex/releases/download/rust-v{pin['version']}/codex-{pin['target']}.tar.gz")
        self.assertIn(pin['url'], readme)
        self.assertIn('curl --fail --location', readme)
        self.assertIn(f"codex-{pin['target']}", readme)
        self.assertIn('share/ditto/codex', readme)
        primary = readme.split('```sh', 1)[1].split('```', 1)[0]
        self.assertNotIn('.local/bin/codex', primary)

    def test_missing(self):
        self.check_selection(None, 'backend_unsupported')

    def test_wrong_hash(self):
        self.check_selection(b'wrong fixture', 'backend_unsupported')

    def test_pinned(self):
        self.check_selection(b'pinned fixture', 'available')


if __name__ == '__main__':
    unittest.main()
