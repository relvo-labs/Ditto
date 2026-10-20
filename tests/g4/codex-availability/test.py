#!/usr/bin/env python3
"""Development regression: execute installer selection and session env blocks.

No install, network, systemd, compositor or real Codex is invoked.
"""
import hashlib
import json
import os
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
            env_block = session[session.rindex('{\n', 0, session.index('  echo "WAYFIRE_SOCKET=')):session.index('chmod 0600 "$session_env"')]
            # Render exactly the installer-owned status placeholder, then run
            # the production env-file block without launching a desktop.
            script = selection + '\n' + env_block.replace('@DITTO_CODEX_STATUS@', '${agent_backend_status}')
            result = subprocess.run(['bash', '-eu', '-c', script], env={**os.environ,
                'workspace': directory, 'DITTO_CODEX_BINARY': str(codex),
                'WAYFIRE_SOCKET': 'fixture', 'variant': '', 'session_env': str(scratch / 'session.env')},
                text=True, capture_output=True, check=True)
            self.assertIn('DITTO_CODEX_STATUS=' + expected, (scratch / 'session.env').read_text())
            if expected == 'backend_unsupported':
                self.assertIn('API', result.stderr)
                self.assertIn('fixture', result.stderr)
                self.assertIn('重新登入', result.stderr)
            else:
                self.assertIn('pinned fixture', result.stderr)

    def test_missing(self):
        self.check_selection(None, 'backend_unsupported')

    def test_wrong_hash(self):
        self.check_selection(b'wrong fixture', 'backend_unsupported')

    def test_pinned(self):
        self.check_selection(b'pinned fixture', 'available')


if __name__ == '__main__':
    unittest.main()
