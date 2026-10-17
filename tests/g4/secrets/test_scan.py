import base64
from pathlib import Path
import sqlite3
import subprocess
import tempfile
import unittest

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


if __name__ == "__main__":
    unittest.main()
