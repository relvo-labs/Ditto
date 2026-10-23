#!/usr/bin/env python3
"""EX1-04 ①: Dock A/B swapped back and forth against the real Shell.

  dock_cycle.py <result.json> <cycles> <warmup>

Runs in the headless desktop of tests/g1/lib/shell-fixture.sh and talks to
Core only through the verification relay. The pill Dock is added once
(outside the counted cycles); every cycle then re-binds ui.dock to the other
entry with one ChangeSet and waits until the Shell reports that entry
mounted. Every 10 cycles a snapshot: Core's bindings, leases and
subscriptions (desktop.plugins.diagnostics), the Shell's mounted providers
(desktop.panels.list) and the Shell's PSS from /proc/<pid>/smaps_rollup.
The result has the shape judge.py reads (with --process shell).
"""

import json
import os
import sys
import time
from pathlib import Path

PILL_VERSION = json.loads((Path(__file__).resolve().parents[3]
                           / "shell/providers/dock_pill/manifest.json").read_text())["version"]

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "lib"))
from gui import relay  # noqa: E402


def result(method, params=None):
    answer = relay(method, params or {})
    if "error" in answer:
        raise RuntimeError(f"{method}: {answer['error']}")
    return answer["result"]


def shell_pid():
    path = os.path.join(os.environ["DITTO_RUNTIME_DIR"], "shell.pid")
    return int(open(path, encoding="utf-8").read().split()[0])


def pss_kib(pid):
    for line in open(f"/proc/{pid}/smaps_rollup", encoding="utf-8"):
        if line.startswith("Pss:"):
            return int(line.split()[1])
    return None


def snapshot(cycle):
    diagnostics = result("desktop.plugins.diagnostics")
    panels = result("desktop.panels.list")["panels"]
    counts = dict(diagnostics.get("core") or {})
    counts["shell_mounted_providers"] = sum(1 for panel in panels if panel.get("mounted"))
    pid = shell_pid()
    return {"cycle": cycle, "at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "counts": counts,
            "shell_pid": pid, "shell_pss_kib": pss_kib(pid)}


def dock_entry():
    return result("desktop.profiles.get")["document"]["slots"]["ui.dock"]


def wait_mounted(entry, timeout=15.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        for panel in result("desktop.panels.list")["panels"]:
            if panel["slot"] == "ui.dock" and panel.get("mounted_entry") == entry and panel.get("mounted"):
                return True
        time.sleep(0.05)
    return False


def propose(ops):
    head = result("desktop.profiles.get")["profile"]["head_revision"]
    change = result("desktop.changes.propose", {"base_revision": head, "ops": ops})
    return change


def main():
    output, cycles, warmup = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
    started = time.monotonic()
    try:
        bottom = dock_entry()
        change = propose([{"op": "add_entry", "slot": "ui.dock",
                           "entry": {"package": "ditto.dock.pill", "version": PILL_VERSION, "host": "qml", "config": {}, "disabled": False}}])
        if change["state"] != "committed":
            raise RuntimeError(f"adding the pill Dock ended {change['state']}")
        pill = dock_entry()
        current = pill
        if not wait_mounted(pill):
            raise RuntimeError("the Shell never mounted the pill Dock")

        def swap():
            nonlocal current
            target = bottom if current == pill else pill
            change = propose([{"op": "bind_slot", "slot": "ui.dock", "from": current, "to": target}])
            if change["state"] != "committed" or not wait_mounted(target):
                raise RuntimeError(f"swap to {target} ended {change['state']} (mounted: {wait_mounted(target, 1)})")
            current = target

        for _ in range(warmup):
            swap()
        snapshots = [snapshot(0)]
        for i in range(1, cycles + 1):
            swap()
            if i % 10 == 0:
                snapshots.append(snapshot(i))
        record = {"ok": True, "group": "dock-swap", "cycles": cycles, "warmup": warmup,
                  "seconds": round(time.monotonic() - started, 1), "snapshots": snapshots}
    except Exception as error:  # the judge turns this into a fail
        record = {"ok": False, "error": str(error)}
    with open(output, "w", encoding="utf-8") as handle:
        json.dump(record, handle, ensure_ascii=False)


if __name__ == "__main__":
    main()
