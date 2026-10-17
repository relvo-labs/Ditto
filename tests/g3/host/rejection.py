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

# Reproduce both the early setup error and the long checkout that exposed
# it on the Actions runner. These are real filesystem paths, no fault flag.
work = root / "artifacts/g3" / f"rejection-{os.getpid()}"
early = work / "early"
early.mkdir(parents=True)
(early / "artifacts").write_text("not a directory")
result = subprocess.run([str(binary), "probe", "files", "--deadline-ms", "3000"], cwd=early, env=environment, capture_output=True, text=True, timeout=15)
report = json.loads(result.stdout)
(early / "report.json").write_text(result.stdout)
assert result.returncode == 2 and report["boundary"]["enforcement"] == "unavailable", report
assert report["completion"] is None and not report["cleanup_complete"] and not report["candidate_activation_available"], report
print("early filesystem error: complete unavailable report, no claimed execution or cleanup", flush=True)

long_path = work / ("long-checkout-" * 12)
long_path.mkdir()
manager = dict(os.environ, XDG_RUNTIME_DIR=f"/run/user/{os.getuid()}", DBUS_SESSION_BUS_ADDRESS=f"unix:path=/run/user/{os.getuid()}/bus")
result = subprocess.run([str(binary), "probe", "network", "--deadline-ms", "3000"], cwd=long_path, env=manager, capture_output=True, text=True, timeout=15)
report = json.loads(result.stdout)
(long_path / "report.json").write_text(result.stdout)
expected = "partial" if "--old-abi" in sys.argv else "full"
assert report["boundary"]["enforcement"] == expected and report["cleanup_complete"], report
assert not report["candidate_activation_available"], report
if expected == "full":
    assert result.returncode == 0 and report["completion"]["exit_code"] == 0, report
else:
    assert result.returncode == 2 and report["completion"] is None, report
print("long checkout: actual network boundary and cleanup verified, " + expected, flush=True)

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
