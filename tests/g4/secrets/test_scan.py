import base64
from contextlib import closing, redirect_stdout
import io
import json
from pathlib import Path
import runpy
import sqlite3
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from scan import scan


class ScannerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.sentinels = {"key": "sk-QA04-synthetic-only-測試!"}

    def run_scan(self):
        return scan({"fixture": str(self.root)}, self.sentinels)

    def test_positive_and_deliberate_leak(self):
        log = self.root / "log"
        log.write_text("credential_ref=cred-example")
        self.assertTrue(self.run_scan()["ok"])
        log.write_text(self.sentinels["key"])
        report = self.run_scan()
        self.assertFalse(report["ok"])
        self.assertGreater(report["hit_count"], 0)
        self.assertEqual(report["hits"][0]["source"], str(log))

    def test_utf16_sqlite_content_is_decoded(self):
        with sqlite3.connect(self.root / "store.sqlite") as db:
            db.execute("PRAGMA encoding='UTF-16'")
            db.execute("CREATE TABLE secrets (value TEXT)")
            db.execute("INSERT INTO secrets VALUES (?)", [self.sentinels["key"]])
        report = self.run_scan()
        self.assertFalse(report["ok"])
        self.assertTrue(any("#sql:" in hit["source"] for hit in report["hits"]))

    def test_base64_and_compressed_package(self):
        source = self.root / "source"
        source.mkdir()
        (source / "data").write_bytes(base64.b64encode(self.sentinels["key"].encode()))
        archive = self.root / "sample.dittopkg"
        subprocess.run(["tar", "--zstd", "-cf", str(archive), "-C", str(source), "data"],
                       check=True, timeout=30)
        (source / "data").unlink()
        report = self.run_scan()
        self.assertFalse(report["ok"])
        self.assertTrue(any("!data" in hit["source"] for hit in report["hits"]))

    def test_missing_empty_symlink_and_corrupt_database_fail_closed(self):
        self.assertFalse(self.run_scan()["ok"])
        self.assertFalse(scan({"missing": str(self.root / "absent")}, self.sentinels)["ok"])
        (self.root / "link").symlink_to("/etc/hostname")
        self.assertTrue(self.run_scan()["errors"])
        (self.root / "link").unlink()
        (self.root / "bad.sqlite").write_bytes(b"SQLite format 3\0" + b"broken")
        self.assertTrue(self.run_scan()["errors"])

    def test_missing_or_empty_sentinels_cannot_pass(self):
        (self.root / "log").write_text("safe")
        for sentinels in ({}, {"key": ""}):
            self.assertFalse(scan({"fixture": str(self.root)}, sentinels)["ok"])

    def test_product_negative_control_exit_status_is_enforced_without_ipc(self):
        # Only the product flow is simulated. The real runner creates its
        # sentinel, scans real fixture files/SQLite and chooses its CLI exit.
        # This is an exit-policy unit test, never product-flow evidence.
        runner = Path(__file__).with_name("run.py")
        real_glob = Path.glob

        def builtin_glob(path, pattern, **kwargs):
            if path.name == "ditto-packages" and pattern == "*.dittopkg":
                return iter([path / "fixture.dittopkg"])
            return real_glob(path, pattern, **kwargs)

        cases = [("expected-only", True, False, True, 0),
                 ("failed-flow", False, False, True, 1),
                 ("unexpected-leak", True, True, True, 1),
                 ("clean-positive", True, False, False, 0),
                 ("leaking-positive", True, True, False, 1),
                 ("private-proposal-leak", True, "proposal", False, 1)]
        for name, flow_ok, unexpected, inject, expected in cases:
            with self.subTest(name=name):
                output = self.root / name

                class FlowFixture:
                    pid = 999999

                    def __init__(self, *_args, env, stdout, **_kwargs):
                        product = Path(env["DITTO_QA04_ROOT"]) / "product"
                        store = Path(env["DITTO_DATA_DIR"])
                        store.mkdir()
                        with closing(sqlite3.connect(store / "fixture.sqlite")) as db:
                            db.execute("CREATE TABLE fixture (value TEXT)")
                        for category in ("exports", "diagnostics", "conversations", "generated"):
                            (product / category / "fixture.json").write_text("{}")
                        (product / "conversations/proposal.json").write_text("QA04_PRIVATE_PROPOSAL_CONTENT")
                        stdout.write("fixture-only log\n")
                        if unexpected:
                            sentinel = ("QA04_PRIVATE_PROPOSAL_CONTENT" if unexpected == "proposal"
                                        else json.loads(env["DITTO_QA04_SENTINELS"])["token"])
                            (product / "logs/unexpected.log").write_text(sentinel)
                        (output / "driver.json").write_text(json.dumps({"ok": flow_ok, "checks": ["simulated flow only"]}))

                    def poll(self):
                        return None

                    def wait(self, timeout):
                        return 0

                argv = [str(runner), "--output", str(output)] + (["--inject-leak"] if inject else [])
                with patch("sys.argv", argv), patch.object(Path, "glob", builtin_glob), \
                     patch("subprocess.Popen", FlowFixture), patch("os.killpg"), \
                     patch("resource.setrlimit"), redirect_stdout(io.StringIO()):
                    with self.assertRaises(SystemExit) as exited:
                        runpy.run_path(str(runner), run_name="__main__")
                report = json.loads((output / "result.json").read_text())
                self.assertEqual(report["flow"]["ok"], flow_ok)
                self.assertEqual(exited.exception.code, expected)
                if unexpected == "proposal":
                    self.assertEqual(report["hit_count"], 0)
                    self.assertGreater(report["default_privacy_scan"]["hit_count"], 0)
                    self.assertFalse(report["ok"])
                if inject and expected == 0:
                    self.assertTrue(report["negative_control_passed"])
                    self.assertGreater(report["hit_count"], 0)
                    self.assertTrue(all(hit["source"] == str(output / "product/logs/intentional-leak.log")
                                        for hit in report["hits"]))


if __name__ == "__main__":
    unittest.main()
