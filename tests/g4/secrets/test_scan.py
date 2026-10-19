import base64
from contextlib import closing, redirect_stdout
import io
import json
import os
from pathlib import Path
import random
import runpy
import sqlite3
import subprocess
import sys
import tempfile
import unittest
import urllib.parse
from unittest.mock import patch

from scan import MIN_SENTINEL_BYTES, scan


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
        with closing(sqlite3.connect(self.root / "store.sqlite")) as db, db:
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
                 ("private-proposal-leak", True, "proposal", False, 1),
                 ("hex", True, False, True, 0),
                 ("base64-offset-1", True, False, True, 0),
                 ("unresolved-keyring", True, False, False, 1)]
        for name, flow_ok, unexpected, inject, expected in cases:
            with self.subTest(name=name):
                output = self.root / name
                child_envs = []

                class FlowFixture:
                    pid = 999999

                    def __init__(self, *_args, env, stdout, **_kwargs):
                        child_envs.append(dict(env))
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
                        (Path(env['DITTO_RUNTIME_DIR']) / 'keyring.json').write_text(json.dumps({
                            'calls': {'CreateItem': 3, 'GetSecret': 0 if name == 'unresolved-keyring' else 3}}))
                        (output / "driver.json").write_text(json.dumps({"ok": flow_ok, "checks": ["simulated flow only"]}))

                    def poll(self):
                        return None

                    def wait(self, timeout):
                        return 0

                class BusFixture:
                    def __init__(self, scratch, *_args):
                        self.address = 'unix:path=' + str(scratch) + '/bus'
                    def start(self):
                        return self.address
                    def stop(self):
                        pass

                argv = [str(runner), "--output", str(output), '--scratch', str(self.root)] + (["--inject-leak"] if inject else [])
                if name in ('hex', 'base64-offset-1'):
                    argv += ['--leak-form', name]
                with patch('private_bus.PrivateBus', BusFixture), patch("sys.argv", argv), patch.object(Path, "glob", builtin_glob), \
                     patch("subprocess.Popen", FlowFixture), patch("os.killpg"), \
                     patch("resource.setrlimit"), redirect_stdout(io.StringIO()):
                    with self.assertRaises(SystemExit) as exited:
                        runpy.run_path(str(runner), run_name="__main__")
                report = json.loads((output / "result.json").read_text())
                self.assertEqual(report["flow"]["ok"], flow_ok and name != "unresolved-keyring")
                # Runner-generated sentinels always meet the scanner's minimum length.
                self.assertEqual(report["errors"], [])
                # Second line of defence: the product's XDG runtime is this run's
                # private scratch directory, removed by the existing cleanup.
                child_env = child_envs[0]
                runtime = Path(child_env["XDG_RUNTIME_DIR"])
                self.assertEqual(child_env["XDG_RUNTIME_DIR"], child_env["DITTO_RUNTIME_DIR"])
                self.assertEqual(runtime.parent, self.root.resolve())
                self.assertNotEqual(child_env["XDG_RUNTIME_DIR"], os.environ.get("XDG_RUNTIME_DIR"))
                self.assertFalse(runtime.exists())
                self.assertTrue((output / "product/runtime/keyring.json").is_file())
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


class SentinelLengthTests(unittest.TestCase):
    def test_threshold_is_sixteen_bytes(self):
        # 16 bytes keep at least 20 Base64 characters entirely inside the value
        # at every offset (120 bits), the same floor as the shared nonce.
        self.assertEqual(MIN_SENTINEL_BYTES, 16)

    def test_short_sentinels_fail_closed_with_a_clear_error(self):
        with tempfile.TemporaryDirectory() as directory:
            # Short Base64 needles such as 'YW' would hit ordinary text.
            (Path(directory) / 'log').write_text('YWJj ordinary base64 text')
            for short in ('ab', 'x' * 15, '測試測試測'):  # The last one is 15 UTF-8 bytes.
                with self.subTest(length=len(short.encode())):
                    result = scan({'fixture': directory}, {'tiny': short})
                    self.assertFalse(result['ok'])
                    self.assertEqual(result['hits'], [])
                    self.assertIn('sentinel tiny must contain at least 16 bytes', result['errors'])
                    self.assertNotIn(short, ' '.join(result['errors']))  # The value is not echoed.
            # Exactly 16 bytes, including multi-byte text, is accepted.
            for value in ('x' * 16, '測試測試測x'):
                self.assertTrue(scan({'fixture': directory}, {'key': value})['ok'])

    def test_default_runner_and_control_sentinels_pass(self):
        nonce = '0' * 32  # run.py uses uuid4().hex: always 32 characters.
        defaults = {'api_key': 'sk-ditto-qa04-' + nonce, 'token': 'ghp_ditto_qa04_' + nonce,
                    'password': 'qa04-password:' + nonce + '!',
                    'control': 'sk-prefix-qa04-7e98c63da14b492bbd21-synthetic-only-suffix',
                    'conversation_content': 'QA04_PRIVATE_CONVERSATION_CONTENT',
                    'proposal_content': 'QA04_PRIVATE_PROPOSAL_CONTENT'}
        with tempfile.TemporaryDirectory() as directory:
            (Path(directory) / 'clean').write_text('credential_ref=cred-example')
            result = scan({'fixture': directory}, defaults, nonce=nonce)
            self.assertEqual(result['errors'], [])
            self.assertTrue(result['ok'])

    def test_cli_rejects_a_short_manifest_sentinel(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'fixture').mkdir()
            (root / 'fixture/clean').write_text('safe')
            manifest = root / 'manifest.json'
            manifest.write_text(json.dumps({'roots': {'fixture': str(root / 'fixture')}, 'sentinels': {'key': 'ab'}}))
            completed = subprocess.run([sys.executable, str(Path(__file__).with_name('scan.py')), str(manifest),
                                        '--output', str(root / 'result.json')],
                                       capture_output=True, text=True, timeout=30)
            self.assertEqual(completed.returncode, 1)
            self.assertIn('sentinel key must contain at least 16 bytes', completed.stdout)


class NonceFormsTests(unittest.TestCase):
    def test_invalid_nonce_fails_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            (Path(directory) / 'clean').write_text('safe reference')
            for nonce in ('', 'too-short', 42):
                self.assertFalse(scan({'fixture': directory}, {'key': 'long-synthetic-sentinel'}, nonce=nonce)['ok'])

    def test_full_sentinel_forms_and_unrelated_content(self):
        sentinel = 'sk-QA04-測試-"/synthetic-only!'
        forms = [lambda value: value.encode(), lambda value: json.dumps(value)[1:-1].encode(),
                 lambda value: urllib.parse.quote(value, safe='').encode()]
        with tempfile.TemporaryDirectory() as directory:
            for index, encode in enumerate(forms):
                for value, hit in ((sentinel, True), ('completely-unrelated-content', False)):
                    with self.subTest(form=index, hit=hit):
                        (Path(directory) / 'log').write_bytes(encode(value))
                        result = scan({'fixture': directory}, {'key': sentinel})
                        self.assertEqual(bool(result['hits']), hit)
                        self.assertEqual(result['ok'], not hit)

    def test_nonce_forms_and_unrelated_content(self):
        # Unicode makes standard and URL-safe alphabets differ at every offset.
        nonce = 'a9f03b7e測試🿿' * 3
        unrelated = 'b8e12c6d獨立🿾' * 3
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'leak'
            forms = [('literal', lambda value: value.encode()),
                     ('hex-lower', lambda value: value.encode().hex().encode()),
                     ('hex-upper', lambda value: value.encode().hex().upper().encode())]
            rng = random.Random(74099)  # Reproducible random prefixes; independent of scanner construction.
            for offset in range(3):
                prefixes = [('empty', b'')] if offset == 0 else [
                    ('ff', b'\xff' * offset), ('zero', b'\x00' * offset), ('random', rng.randbytes(offset))]
                for prefix_name, prefix in prefixes:
                    for urlsafe in (False, True):
                        for padding in (False, True):
                            def encode(value, prefix=prefix, urlsafe=urlsafe, padding=padding):
                                fn = base64.urlsafe_b64encode if urlsafe else base64.b64encode
                                result = fn(prefix + value.encode() + b'!suffix')
                                return result if padding else result.rstrip(b'=')
                            forms.append((f'base64-{offset}-{prefix_name}-{urlsafe}-{padding}', encode))
            for name, encode in forms:
                for value, expected in ((nonce, False), (unrelated, True)):
                    with self.subTest(form=name, leaked=value == nonce):
                        path.write_bytes(encode(value))
                        result = scan({'fixture': directory}, {'key': 'sk-prefix-' + nonce + '-suffix'}, nonce=nonce)
                        self.assertEqual(result['ok'], expected)
                        self.assertEqual(bool(result['hits']), not expected)
                        self.assertNotIn(nonce, json.dumps(result['hits']))


if __name__ == "__main__":
    unittest.main()
