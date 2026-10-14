"""Actual fixed Qt runner failures, in bounded services and ditto-confine.

These are trusted test fixtures, never candidate artifacts or production
templates. No fault switch or arbitrary-source entrance is added to Core.
"""
import datetime
import json
import os
import pathlib
import socket
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[3]
NATIVE = ROOT / "target/debug/ditto-generation-runner"
CONFINE = ROOT / "target/debug/ditto-confine"
PIN = json.loads(NATIVE.with_suffix(".json").read_text())
STAGES = ["syntax", "contract", "load", "focus", "interaction"]


def inside(work):
    group = next(line.split("::", 1)[1] for line in pathlib.Path("/proc/self/cgroup").read_text().splitlines() if line.startswith("0::"))
    cg = pathlib.Path("/sys/fs/cgroup") / group.lstrip("/")
    limits = {name: (cg / name).read_text().strip() for name in ["memory.max", "memory.swap.max", "cpu.max", "pids.max"]}
    expected = {"memory.max": "536870912", "memory.swap.max": "0", "cpu.max": "100000 100000", "pids.max": "64"}
    if limits != expected:
        print(json.dumps({"not_run": "actual limits differ", "limits": limits}))
        return 2
    tmp = work / "tmp"
    tmp.mkdir(mode=0o700)
    ours, theirs = socket.socketpair()
    ours.settimeout(5)
    cmd = [str(CONFINE), "--status-fd", str(theirs.fileno())]
    for p in ["/usr", "/lib", "/lib64", "/etc/fonts", "/dev/urandom", PIN["qt_prefix"], str(NATIVE), str(work / "description.json"), str(work / "Panel.qml")]:
        if pathlib.Path(p).exists():
            cmd += ["--read", p]
    cmd += ["--write", str(tmp), "--write", "/dev/null", "--cwd", str(tmp)]
    for entry in [f"HOME={tmp}", f"XDG_CACHE_HOME={tmp}", "LANG=C.UTF-8", "QT_QPA_PLATFORM=offscreen", "QT_QUICK_BACKEND=software", "QSG_RENDER_LOOP=basic", "QT_ACCESSIBILITY=0", f"LD_LIBRARY_PATH={PIN['qt_prefix']}/lib", f"QML_IMPORT_PATH={PIN['qt_prefix']}/qml"]:
        cmd += ["--env", entry]
    cmd += ["--", str(NATIVE), "validate", str(work / "description.json"), str(work / "Panel.qml")]
    child = subprocess.Popen(cmd, env={}, pass_fds=(theirs.fileno(),), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    theirs.close()
    try:
        raw = b""
        while True:
            part = ours.recv(4097 - len(raw))
            if not part:
                break
            raw += part
            if len(raw) > 4096:
                raise RuntimeError("oversized confinement status")
        status = json.loads(raw or b"{}")
        stdout, stderr = child.communicate(timeout=8)
        events = [json.loads(line) for line in stdout.splitlines() if line.startswith("{")]
        result = next((e["native_result"] for e in events if "native_result" in e), None)
        report = {"cgroup": group, "limits": limits, "confine_status": status, "native": result, "timings": [e["stage_timing"] for e in events if "stage_timing" in e], "exit_code": child.returncode, "stderr": stderr[-8192:]}
        if not status.get("confined") or result is None:
            report["not_run"] = "native runner did not execute under verified confinement"
            print(json.dumps(report))
            return 2
        print(json.dumps(report))
        return 0
    finally:
        if child.poll() is None:
            child.kill()
            child.wait()
        ours.close()


def main():
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    out = ROOT / "artifacts/g3" / f"native-failures-{stamp}-{os.getpid()}"
    out.mkdir(mode=0o700, parents=True)
    summary = {"evidence_class": "development-fixed-native-failures", "source": json.loads(subprocess.check_output(["python3", str(ROOT / "tests/g3/source.py")], text=True)), "witness_pid": os.getpid(), "checks": [], "candidate_activation": False}
    env = dict(os.environ, DBUS_SESSION_BUS_ADDRESS=f"unix:path=/run/user/{os.getuid()}/bus")
    base = json.loads((ROOT / "crates/ditto-generation/examples/tasks-summary.json").read_text())
    minimal = "import QtQuick\nItem { width:320; height:120; property var config: ({}); property var tasks: []; property bool testData:false; property bool dataAvailable:false; property bool ready:READY; property var displayedTasks: []; function healthy() { return ready }\n ENABLED }\n"
    try:
        for case in ["control", *STAGES, "illegal-import"]:
            work = out / case
            work.mkdir()
            description = dict(base)
            source = (ROOT / "crates/ditto-generation/templates/TasksSummary.qml").read_text()
            if case == "syntax":
                source = "import QtQuick\nItem {"
            elif case == "illegal-import":
                source = "import Ditto.Forbidden 1.0\nItem {}"
            elif case == "contract":
                description["format_version"] = 0
            elif case in ["load", "focus", "interaction"]:
                source = minimal.replace("READY", "false" if case == "load" else "true").replace("ENABLED", "enabled:false" if case == "focus" else "")
            (work / "description.json").write_text(json.dumps(description))
            (work / "Panel.qml").write_text(source)
            unit = f"ditto-g3-native-{os.getpid()}-{case}.service"
            cmd = ["systemd-run", "--user", "--quiet", "--wait", "--pipe", "--service-type=exec", f"--unit={unit}"]
            for prop in ["MemoryMax=512M", "MemorySwapMax=0", "CPUQuota=100%", "TasksMax=64", "RuntimeMaxSec=10s", "TimeoutStopSec=1s", "KillMode=control-group", "NoNewPrivileges=yes"]:
                cmd += ["-p", prop]
            cmd += [sys.executable, str(pathlib.Path(__file__).resolve()), "--inside", str(work)]
            report = None
            try:
                completed = subprocess.run(cmd, env=env, capture_output=True, text=True, timeout=20)
                (work / "stdout.json").write_text(completed.stdout)
                (work / "stderr.log").write_text(completed.stderr)
                report = json.loads(completed.stdout)
            finally:
                subprocess.run(["systemctl", "--user", "stop", unit], env=env, capture_output=True, timeout=5)
                subprocess.run(["systemctl", "--user", "reset-failed", unit], env=env, capture_output=True, timeout=5)
            if report.get("not_run"):
                summary["checks"].append({"check": case, "status": "not_run", "reason": report})
                return 2
            cg = pathlib.Path("/sys/fs/cgroup") / report["cgroup"].lstrip("/")
            assert not cg.exists() or "populated 0" in (cg / "cgroup.events").read_text(), report
            assert report["native"]["exec_blocked"] and not report["native"]["preview_opened"], report
            expected_failure = None if case == "control" else ("syntax" if case == "illegal-import" else case)
            failure_index = STAGES.index(expected_failure) if expected_failure else len(STAGES)
            expected = ["passed" if i < failure_index else "failed" if i == failure_index else "not_run" for i in range(5)]
            assert [s["stage"] for s in report["native"]["stages"]] == STAGES, report
            assert [s["result"] for s in report["native"]["stages"]] == expected, report
            assert len(report["timings"]) == min(failure_index + 1, 5), report
            os.kill(os.getpid(), 0)
            summary["checks"].append({"check": case, "status": "pass", "failure_stage": expected_failure, "cleanup_complete": True})
            print(f"PASS native {case}: {expected}", flush=True)
    except Exception as error:
        summary["checks"].append({"check": "assertion", "status": "fail", "error": str(error)})
        raise
    finally:
        (out / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
        print("Evidence: " + str(out), flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(inside(pathlib.Path(sys.argv[2])) if len(sys.argv) == 3 and sys.argv[1] == "--inside" else main())
