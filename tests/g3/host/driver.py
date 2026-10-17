"""G3 fixed-probe OS checks. Save every result, including not_run and failures.

This runner never executes a fault outside the native test-host boundary.
It checks a scope-outside witness (itself), not a fabricated desktop PID.
The later desktop acceptance suite must add real Core/Shell/hostd/revision.
"""
import datetime
import json
import os
import pathlib
import signal
import subprocess
import sys
import time

root = pathlib.Path(__file__).resolve().parents[3]
stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H-%M-%SZ")
out = pathlib.Path(os.environ.get("DITTO_ARTIFACTS", root / "artifacts/g3")) / ("host-" + stamp + "-" + str(os.getpid()))
out.mkdir(parents=True)
binary = pathlib.Path(os.environ.get("DITTO_BINARIES", root / "target/debug")) / "ditto-test-host"
physical = None
if os.environ.get("DITTO_G3_PHYSICAL_CONTEXT"):
    sys.path.insert(0, str(root / "tests/g3/reference"))
    import observe as physical
    # Guard is re-evaluated against live logind, DRM and private Core state.
    physical.guard()
summary = {
    "evidence_class": os.environ.get("DITTO_ENVIRONMENT_LABEL", "development-host"),
    "commit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip(),
    "dirty": bool(subprocess.check_output(["git", "status", "--porcelain"], cwd=root)),
    "kernel": os.uname().release,
    "witness_pid": os.getpid(),
    "policy": "diagnostic-v1",
    "desktop_acceptance": "not_run",
    "checks": [],
}


def save():
    (out / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")


def check_report(kind, report, expected):
    assert report["outcome"] == expected, report
    assert report["boundary"]["enforcement"] == "full", report
    assert report["boundary"]["policy"] == "diagnostic-v1", report
    assert report["cleanup_complete"], report
    assert not report["candidate_activation_available"], report
    assert all(report["boundary"][field] for field in ("files", "network", "processes", "time")), report
    os.kill(os.getpid(), 0)  # The scope-outside witness still exists.
    # A fake JSON line can only appear inside untrusted diagnostic output.
    if kind == "spoof":
        assert "generated-v1" in report["completion"]["output"], report
        assert report["boundary"]["policy"] != "generated-v1", report


try:
    for kind, expected in [
        ("files", "succeeded"), ("network", "succeeded"), ("signals", "succeeded"),
        ("spawn", "succeeded"), ("spoof", "succeeded"), ("memory", "oom"),
        ("busy", "timed_out"), ("timeout", "timed_out"),
        ("orphan", "timed_out"),
    ]:
        before = physical.snapshot() if physical else None
        result = subprocess.run([str(binary), "probe", kind, "--deadline-ms", "3000"], cwd=root, capture_output=True, text=True, timeout=20)
        (out / (kind + ".json")).write_text(result.stdout)
        (out / (kind + ".stderr")).write_text(result.stderr)
        report = json.loads(result.stdout)
        if result.returncode == 2:
            summary["checks"].append({"check": kind, "status": "not_run", "reason": report})
            save()
            print("OS boundary unavailable; evidence: " + str(out), file=sys.stderr)
            sys.exit(2)
        check_report(kind, report, expected)
        if physical:
            after = physical.snapshot()
            physical.unchanged(before, after)
            summary["desktop_acceptance"] = "reference-physical-seat"
            summary.setdefault("desktop_witnesses", []).append({"case": kind, "before": before, "after": after})
        summary["checks"].append({"check": kind, "status": "pass"})
        save()
        print(kind + ": pass", flush=True)

    before = physical.snapshot() if physical else None
    process = subprocess.Popen([str(binary), "probe", "timeout", "--deadline-ms", "10000"], cwd=root, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    time.sleep(1)
    process.send_signal(signal.SIGTERM)
    stdout, stderr = process.communicate(timeout=15)
    (out / "cancel.json").write_text(stdout)
    (out / "cancel.stderr").write_text(stderr)
    check_report("cancel", json.loads(stdout), "cancelled")
    if physical:
        after = physical.snapshot()
        physical.unchanged(before, after)
        summary.setdefault("desktop_witnesses", []).append({"case": "cancel", "before": before, "after": after})
    summary["checks"].append({"check": "cancel", "status": "pass"})
    save()
    print("cancel: pass; evidence: " + str(out), flush=True)
except Exception as error:
    summary["checks"].append({"check": "assertion", "status": "fail", "error": str(error)})
    save()
    raise
