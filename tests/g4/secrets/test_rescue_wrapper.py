"""Exercise the standalone rescue wrapper without Qt or a real session."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class RescueWrapperTest(unittest.TestCase):
    def test_crashed_quickshell_disables_handler_and_falls_back_to_foot(self):
        wrapper = Path(__file__).resolve().parents[3] / "packaging/reference-image/session/ditto-rescue-ui"
        with tempfile.TemporaryDirectory(prefix="rescue-wrapper-") as temporary:
            root = Path(temporary)
            qml = root / "shell/rescue/shell.qml"
            qml.parent.mkdir(parents=True)
            qml.write_text("// fixture\n")
            binary = root / "bin"
            binary.mkdir()
            quickshell = binary / "quickshell"
            quickshell.write_text('#!/bin/sh\nprintf "%s" "${QS_DISABLE_CRASH_HANDLER-unset}" > "$RESCUE_FIXTURE_FLAG"\nexit 139\n')
            quickshell.chmod(0o755)
            foot = binary / "foot"
            foot.write_text('#!/bin/sh\nprintf "%s" "$*" > "$RESCUE_FIXTURE_FOOT"\n')
            foot.chmod(0o755)
            environment = dict(os.environ, DITTO_WORKSPACE=str(root), DITTO_QT_PREFIX=str(root),
                               PATH=str(binary) + os.pathsep + os.environ["PATH"],
                               RESCUE_FIXTURE_FLAG=str(root / "flag"), RESCUE_FIXTURE_FOOT=str(root / "fallback"))
            environment.pop("QS_DISABLE_CRASH_HANDLER", None)
            result = subprocess.run(["bash", str(wrapper)], env=environment, capture_output=True, text=True, check=False)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("dittoctl rescue", (root / "fallback").read_text())
            self.assertEqual((root / "flag").read_text(), "1")


if __name__ == "__main__":
    unittest.main()
