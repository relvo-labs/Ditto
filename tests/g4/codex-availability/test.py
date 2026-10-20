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
    def check_selection(self, binary, expected):
        with tempfile.TemporaryDirectory(prefix="codex-availability-") as directory:
            scratch = Path(directory)
            pin = scratch / "tools/codex/pin.json"
            pin.parent.mkdir(parents=True)
            pin.write_text(json.dumps({"version": "fixture", "sha256": hashlib.sha256(b"pinned fixture").hexdigest()}))
            codex = scratch / "codex"
            if binary is not None:
                codex.write_bytes(binary)
            installer = (ROOT / "packaging/reference-image/install-session.sh").read_text()
            selection = installer[installer.index('codex="$(readlink'):installer.index('bash "$workspace/scripts/build-builtin-packages.sh"')]
            session = (ROOT / "packaging/reference-image/session/ditto-session").read_text()
            env_block = session[session.rindex('{\n', 0, session.index('  echo "WAYFIRE_SOCKET=')):session.index('# D-Bus-activated services')]
            # Render exactly the installer-owned status placeholder, then run
            # the production env-file block without launching a desktop.
            script = selection + '\n{\n' + env_block.replace('@DITTO_CODEX_STATUS@', '${agent_backend_status}') + '\n} 2>"$session_notice"'
            result = subprocess.run(['bash', '-eu', '-c', script], env={**os.environ,
                'workspace': directory, 'DITTO_CODEX_BINARY': str(codex),
                'WAYFIRE_SOCKET': 'fixture', 'variant': '', 'session_env': str(scratch / 'session.env'), 'session_notice': str(scratch / 'notice')},
                text=True, capture_output=True, check=True)
            self.assertIn('DITTO_CODEX_STATUS=' + expected, (scratch / 'session.env').read_text())
            if expected == 'backend_unsupported':
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

    def test_missing(self):
        self.check_selection(None, 'backend_unsupported')

    def test_wrong_hash(self):
        self.check_selection(b'wrong fixture', 'backend_unsupported')

    def test_pinned(self):
        self.check_selection(b'pinned fixture', 'available')


if __name__ == '__main__':
    unittest.main()
