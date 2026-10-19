#!/usr/bin/env python3
"""Scanner-only CLI controls; these are never product-flow evidence."""
import argparse
import base64
from contextlib import closing
import json
from pathlib import Path
import sqlite3
import subprocess
import sys

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--output", type=Path, required=True)
parser.add_argument('--leak-form', choices=('literal', 'hex', 'base64-offset-1'), default='literal')
parser.add_argument("--inject-leak", action="store_true")
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=False)
product = args.output / "fixture"
product.mkdir()
with closing(sqlite3.connect(product / "store.sqlite")) as db, db:
    db.execute("CREATE TABLE settings (credential_ref TEXT)")
    db.execute("INSERT INTO settings VALUES ('cred-test-reference')")
(product / "log.json").write_text('{"credential_ref":"cred-test-reference"}')
nonce = "qa04-7e98c63da14b492bbd21-synthetic-only"
sentinel = "sk-prefix-" + nonce + "-suffix"
if args.inject_leak:
    value = {'literal': sentinel.encode(), 'hex': nonce.encode().hex().upper().encode(),
             'base64-offset-1': base64.b64encode(b'\xff' + nonce.encode() + b'!').rstrip(b'=')}[args.leak_form]
    (product / "deliberate-leak.log").write_bytes(value)
manifest = args.output / "manifest.json"
manifest.write_text(json.dumps({"roots": {"scanner_fixture": str(product)}, "sentinels": {"key": sentinel}, "nonce": nonce}))
completed = subprocess.run([sys.executable, str(Path(__file__).with_name("scan.py")),
                            str(manifest), "--output", str(args.output / "result.json")], timeout=30)
raise SystemExit(completed.returncode)
