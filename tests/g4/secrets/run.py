#!/usr/bin/env python3
"""Headless Core ingress → Agent records → generation → retained disk scan."""
import argparse
import base64
import json
import os
from pathlib import Path
import resource
import shutil
import signal
import subprocess
import tempfile
import time
import uuid

from scan import scan
from private_bus import PrivateBus
from fake_secret_service import private_address

WORKSPACE = Path(__file__).resolve().parents[3]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--output", type=Path, required=True, help="new evidence directory")
parser.add_argument("--scratch", type=Path, required=True, help="private socket parent directory")
parser.add_argument("--leak-form", choices=("literal", "hex", "base64-offset-1"), default="literal")
parser.add_argument("--inject-leak", action="store_true", help="exit 0 only for a completed flow with exactly the expected leak source")
args = parser.parse_args()
root = args.output.resolve()
root.mkdir(parents=True, exist_ok=False)
nonce = uuid.uuid4().hex
sentinels = {"api_key": "sk-ditto-qa04-" + nonce,
             "token": "ghp_ditto_qa04_" + nonce,
             "password": "qa04-password:" + nonce + "!"}
# Inputs are intentionally outside the scanned product output, explicitly listed.
manifest = {"sentinels": sentinels, "nonce": nonce, "roots": {category: str(root / "product" / category)
            for category in ("logs", "exports", "diagnostics", "conversations", "generated", "store", "home", "runtime")}}
(root / "manifest.json").write_text(json.dumps(manifest, indent=2))
product = root / "product"
for category in ("home", "logs", "exports", "diagnostics", "conversations", "generated"):
    (product / category).mkdir(parents=True)
# Short Unix socket paths even when evidence lives in a deep worktree.
runtime = Path(tempfile.mkdtemp(prefix="qa04-", dir=args.scratch.resolve()))
env = {**os.environ, "HOME": str(product / "home"), "DITTO_SYSTEM": "none",
       "DITTO_RUNTIME_DIR": str(runtime), "DITTO_DATA_DIR": str(product / "store"),
       "DBUS_SESSION_BUS_ADDRESS": "unix:path=" + str(runtime / "bus"),
       "DBUS_STARTER_ADDRESS": "unix:path=" + str(runtime / "bus"), "DBUS_STARTER_BUS_TYPE": "session",
       "DITTO_QA04_SCRATCH": str(runtime),
       "DITTO_QA04_ROOT": str(root), "DITTO_QA04_SENTINELS": json.dumps(sentinels)}
for key in ("DITTO_DEV_TOKEN", "DITTO_LAUNCH_SCOPE_PREFIX", "DITTO_REQUIRE_QUOTA",
            "WAYFIRE_SOCKET", "SWAYSOCK", "DITTO_CORE_SOCKET", "DITTO_CORE_TOKEN_FD"):
    env.pop(key, None)
command = [str(WORKSPACE / "target/debug/ditto-core"), "serve", "--compositor", "fixture",
           "--builtin-packages", str(WORKSPACE / "target/ditto-packages"),
           "--hostd", f"hostd 0.2.0 {shutil.which('node')} {WORKSPACE}/packages/host-runtime/dist/ditto-hostd.mjs",
           "--agent", f"agent 0.3.0 {shutil.which('node')} {WORKSPACE}/packages/agent-runtime/dist/ditto-agentd.mjs",
           "--launch", f"dittoctl 0.3.0 {shutil.which('node')} {Path(__file__).with_name('driver.mjs')}"]
status = {"ok": False, "evidence_class": "development-host", "checks": [],
          "not_run": ["Wayfire / Quickshell crash capture and password-unlock recording",
                      "real network model / Codex app-server turn (scripted loopback provider only)",
                      "native isolated generation validation / preview (create and readback only)"]}
child = None
bus = None
bus_log = None
try:
    # The bus/keyring children also inherit the no-dump policy.
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    private_address(runtime, env['DBUS_SESSION_BUS_ADDRESS'])
    bus_log = (product / 'logs/private-bus.log').open('w')
    bus = PrivateBus(runtime, runtime / 'keyring.json', bus_log)
    if bus.start() != env['DBUS_SESSION_BUS_ADDRESS']:
        raise RuntimeError('private bus address mismatch')
    if not list((WORKSPACE / "target/ditto-packages").glob("*.dittopkg")):
        raise RuntimeError("build built-in packages first: bash scripts/build-builtin-packages.sh target/ditto-packages")
    with (product / "logs/core-agent.log").open("w") as log:
        child = subprocess.Popen(command, cwd=WORKSPACE, env=env, stdout=log, stderr=log,
                                 start_new_session=True)
        deadline = time.monotonic() + 90
        while not (root / "driver.json").exists():
            if child.poll() is not None:
                raise RuntimeError("Core exited before driver completed")
            if time.monotonic() >= deadline:
                raise RuntimeError("driver timeout")
            time.sleep(.1)
        status.update(json.loads((root / "driver.json").read_text()))
        keyring = json.loads((runtime / 'keyring.json').read_text())
        status['keyring'] = keyring
        if keyring.get('calls', {}).get('CreateItem', 0) < 3 or keyring.get('calls', {}).get('GetSecret', 0) < 3:
            raise RuntimeError('all three sentinels must be stored and resolved by the private keyring')
except (OSError, RuntimeError, ValueError) as error:
    status["ok"] = False
    status["error"] = str(error)
finally:
    if child:
        try:
            os.killpg(child.pid, signal.SIGTERM)
            child.wait(timeout=5)
        except (ProcessLookupError, subprocess.TimeoutExpired):
            pass
        try:
            os.killpg(child.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        child.wait(timeout=5)
    if bus:
        bus.stop()
    if bus_log:
        bus_log.close()
    # Retain runtime files as part of the scan after processes stop.
    shutil.copytree(runtime, product / "runtime", ignore=lambda p, names: [
        n for n in names if (Path(p) / n).is_socket()])
    shutil.rmtree(runtime)
if not status['ok']:
    status['not_run'].append('complete private-keyring / Agent / hostd / store / export flow (not completed)')
    if 'Operation not permitted' in (product / 'logs/private-bus.log').read_text():
        status['blocked'] = 'sandbox socket'
if args.inject_leak:
    leak = {"literal": sentinels["token"].encode(), "hex": nonce.encode().hex().upper().encode(),
            "base64-offset-1": base64.b64encode(b'x' + nonce.encode() + b'!').rstrip(b'=')}[args.leak_form]
    (product / "logs/intentional-leak.log").write_bytes(leak)
report = scan(manifest["roots"], sentinels, nonce=nonce)
privacy = scan({category: manifest["roots"][category] for category in ("logs", "exports", "diagnostics")},
               {"conversation_content": "QA04_PRIVATE_CONVERSATION_CONTENT",
                "proposal_content": "QA04_PRIVATE_PROPOSAL_CONTENT"})
report.update({"flow": status, "injection_manifest": str(root / "manifest.json"),
               "negative_control": args.inject_leak, "leak_form": args.leak_form, "default_privacy_scan": privacy})
coverage = all(report["scope"][category]["file_count"] > 0 for category in
               ("logs", "exports", "diagnostics", "conversations", "generated", "store"))
report["ok"] = report["ok"] and status["ok"] and privacy["ok"] and coverage and bool(report["sqlite_databases"])
passed = report["ok"]
if args.inject_leak:
    passed = (status["ok"] and privacy["ok"] and coverage and bool(report["sqlite_databases"])
              and not report["errors"] and bool(report["hits"])
              and all(hit["source"] == str(product / "logs/intentional-leak.log") for hit in report["hits"]))
    report["negative_control_passed"] = bool(passed)
(root / "result.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
print(json.dumps({"ok": report["ok"], "file_count": report["file_count"],
                  "hit_count": report["hit_count"], "flow_ok": status["ok"],
                  "negative_control_passed": report.get("negative_control_passed"),
                  "result": str(root / "result.json")}))
raise SystemExit(0 if passed else 1)
