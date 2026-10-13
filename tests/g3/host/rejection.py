"""Executable rejection paths: missing bus, bad arguments, optional old ABI.

Run with --old-abi in the 6.8 VM snapshot. A correct rejection is a passing
check, while all candidate execution tests stay not_run on that kernel.
"""
import json
import os
import pathlib
import subprocess
import sys

root = pathlib.Path(__file__).resolve().parents[3]
binary = root / "target/debug/ditto-test-host"
environment = dict(os.environ, DBUS_SESSION_BUS_ADDRESS="unix:path=/nonexistent/ditto-g3-test-bus")
result = subprocess.run([str(binary), "probe", "files", "--deadline-ms", "3000"], env=environment, capture_output=True, text=True, timeout=15)
report = json.loads(result.stdout)
assert result.returncode == 2, report
assert report["boundary"]["enforcement"] == "unavailable", report
assert report["completion"] is None, report
assert not report["candidate_activation_available"], report
print("missing bus: unavailable, no probe executed", flush=True)

for arguments in [["probe", "arbitrary-command"], ["probe", "files", "--deadline-ms", "0"], ["probe", "files", "--deadline-ms", "120001"], ["__runner", "memory"]]:
    result = subprocess.run([str(binary), *arguments], capture_output=True, text=True, timeout=10)
    assert result.returncode != 0, (arguments, result)
    assert "\"full\"" not in result.stdout
print("unknown probe/invalid deadlines/private runner: rejected", flush=True)

if "--old-abi" in sys.argv:
    result = subprocess.run([str(binary), "probe", "files", "--deadline-ms", "3000"], capture_output=True, text=True, timeout=15)
    report = json.loads(result.stdout)
    assert result.returncode == 2, report
    assert report["boundary"]["enforcement"] == "partial", report
    assert report["boundary"]["landlock_abi"] < 6, report
    assert report["completion"] is None, report
    assert report["cleanup_complete"], report
    assert not report["candidate_activation_available"], report
    print(json.dumps(report), flush=True)
    print("old ABI: partial, no probe executed", flush=True)
