#!/usr/bin/env python3
"""Headless Core ingress → Agent records → generation → retained disk scan."""
import argparse
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

WORKSPACE = Path(__file__).resolve().parents[3]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--output", type=Path, required=True, help="new evidence directory")
parser.add_argument("--inject-leak", action="store_true", help="exit 0 only for a completed flow with exactly the expected leak source")
args = parser.parse_args()
root = args.output.resolve()
root.mkdir(parents=True, exist_ok=False)
nonce = uuid.uuid4().hex
sentinels = {"api_key": "sk-ditto-qa04-" + nonce,
             "token": "ghp_ditto_qa04_" + nonce,
             "password": "qa04-password:" + nonce + "!"}
# Inputs are intentionally outside the scanned product output, explicitly listed.
manifest = {"sentinels": sentinels, "roots": {category: str(root / "product" / category)
            for category in ("logs", "exports", "diagnostics", "conversations", "generated", "store", "home", "runtime")}}
(root / "manifest.json").write_text(json.dumps(manifest, indent=2))
product = root / "product"
for category in ("home", "logs", "exports", "diagnostics", "conversations", "generated"):
    (product / category).mkdir(parents=True)
# Short Unix socket paths even when evidence lives in a deep worktree.
runtime = Path(tempfile.mkdtemp(prefix="qa04-"))
env = {**os.environ, "HOME": str(product / "home"), "DITTO_SYSTEM": "none",
       "DITTO_RUNTIME_DIR": str(runtime), "DITTO_DATA_DIR": str(product / "store"),
       "DBUS_SESSION_BUS_ADDRESS": "unix:path=" + str(runtime / "absent-bus"),
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
                      "successful keyring resolution and network model turn (network disabled)",
                      "native isolated generation validation / preview (create and readback only)"]}
child = None
try:
    if not list((WORKSPACE / "target/ditto-packages").glob("*.dittopkg")):
        raise RuntimeError("build built-in packages first: bash scripts/build-builtin-packages.sh target/ditto-packages")
    # Avoid host-level memory dumps of synthetic secrets from this fixture.
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
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
except (OSError, RuntimeError, ValueError) as error:
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
    # Retain runtime files as part of the scan after processes stop.
    shutil.copytree(runtime, product / "runtime", ignore=lambda p, names: [
        n for n in names if (Path(p) / n).is_socket()])
    shutil.rmtree(runtime)
if args.inject_leak:
    (product / "logs/intentional-leak.log").write_text(sentinels["token"])
report = scan(manifest["roots"], sentinels)
privacy = scan({category: manifest["roots"][category] for category in ("logs", "exports", "diagnostics")},
               {"conversation_content": "QA04_PRIVATE_CONVERSATION_CONTENT",
                "proposal_content": "QA04_PRIVATE_PROPOSAL_CONTENT"})
report.update({"flow": status, "injection_manifest": str(root / "manifest.json"),
               "negative_control": args.inject_leak, "default_privacy_scan": privacy})
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
