"""zh-TW installer screen: QML message parity with messages.py and the offscreen
QML tests (qmltestrunner + the #212 Quickshell stubs). Skips the QML run only
when no Qt 6.10.2 toolchain is found; the parity check always runs."""

import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import unittest

HERE = Path(__file__).resolve().parent
INSTALLER = HERE.parent
REPO = HERE.parents[3]
sys.path.insert(0, str(INSTALLER))

from ditto_installer import messages  # noqa: E402

QML = REPO / "shell/installer"


def qt_prefix():
    for candidate in (os.environ.get("QT_PREFIX"), "/data/hermes/.local/toolchains/qt/6.10.2/gcc_64",
                      os.path.expanduser("~/Qt/6.10.2/gcc_64")):
        if candidate and Path(candidate, "bin/qmltestrunner").is_file():
            return Path(candidate)
    return None


class ParityTests(unittest.TestCase):
    def test_qml_text_matches_python_messages(self):
        source = (QML / "InstallerMessages.qml").read_text()
        functions = dict(re.findall(r"function (\w+)\(code\) \{(.*?)\n    \}", source, re.S))
        tables = {"result": messages.RESULTS, "excluded": messages.EXCLUDED, "stage": messages.STAGES,
                  "diskState": messages.DISK_STATE, "status": messages.STATUS}
        self.assertEqual(set(functions), set(tables))
        for name, table in tables.items():
            cases = dict(re.findall(r'case "([a-z_]+)": return qsTr\("([^"]*)"\);', functions[name]))
            expected = {code: zh for code, (zh, _en) in table.items() if zh}
            self.assertEqual(cases, expected, name)

    def test_screen_contract_strings(self):
        screen = (QML / "InstallerScreen.qml").read_text()
        self.assertEqual(messages.STATUS["erase_warning"][0], "將清除整顆磁碟的全部資料")
        for needle in ('id: cancelConfirm', 'kind: "danger"', "Accessible.role: Accessible.ProgressBar",
                       'if (view === "confirm") cancelConfirm.forceActiveFocus();'):
            self.assertIn(needle, screen)
        client = (QML / "InstallerClient.qml").read_text()
        self.assertIn('property string socketPath: "/run/ditto-installer/backend.sock"', client)
        # The client only ever sends fixed actions with opaque tokens.
        sends = re.findall(r'send\("([a-z]+)"(?:, \{(\w+): \w+(?:\.\w+)?\})?\)', client)
        self.assertEqual({action for action, _ in sends},
                         {"list", "select", "back", "confirm", "cancel", "reboot", "state"})
        self.assertTrue(all(field in ("", "token") for _, field in sends))
        for link in ("core", "i18n", "jelly", "ui", "wallpapers"):
            self.assertEqual(os.readlink(QML / link), "../" + link)


class OffscreenQmlTests(unittest.TestCase):
    def test_qmltestrunner(self):
        qt = qt_prefix()
        if qt is None:
            self.skipTest("Qt 6.10.2 qmltestrunner not found (set QT_PREFIX)")
        env = {**os.environ, "QT_QPA_PLATFORM": "offscreen"}
        result = subprocess.run([str(qt / "bin/qmltestrunner"), "-import", str(REPO / "tests/firstboot/stubs"),
                                 "-input", str(HERE / "tst_installer.qml")], capture_output=True, text=True,
                                env=env, timeout=300)
        output = result.stdout + result.stderr
        self.assertEqual(result.returncode, 0, output[-4000:])
        totals = re.search(r"Totals: (\d+) passed, (\d+) failed", output)
        self.assertIsNotNone(totals, output[-2000:])
        self.assertEqual(totals.group(2), "0", output[-4000:])
        self.assertGreaterEqual(int(totals.group(1)), 9)


if __name__ == "__main__":
    unittest.main()
