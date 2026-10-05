#!/usr/bin/env python3
"""Judge EX1-11 ① and ② from the session driver's samples.

  judge.py <samples.jsonl> <done.json> <local-count> <dock-count>

Prints one JSON object: {"local": {status, detail, evidence}, "dock": {...},
"operations": <judged operations>}. Thresholds are the gate's (① p95 ≤100 ms,
② p95 ≤2000 ms); a sample that was not read back or did not commit, or a
count short of the one asked for, is a fail with the data, never a pass.
Warm-up samples (`warmup: true`) are kept in the file and not judged.
"""

import json
import math
import sys

LOCAL_KINDS = ("workspace_switch", "window_focus", "appearance_token")


def figures(values):
    values = sorted(values)
    if not values:
        return {"n": 0, "p50_ms": None, "p95_ms": None, "max_ms": None}

    def rank(q):
        return values[max(0, math.ceil(q * len(values)) - 1)]

    return {"n": len(values), "p50_ms": round(rank(0.50), 3), "p95_ms": round(rank(0.95), 3),
            "max_ms": round(values[-1], 3)}


def main(path, done_path, local_count, dock_count):
    try:
        samples = [json.loads(line) for line in open(path, encoding="utf-8") if line.strip()]
    except OSError:
        samples = []
    try:
        done = json.load(open(done_path, encoding="utf-8"))
    except (OSError, ValueError):
        done = {"ok": False, "error": "the driver wrote no result"}

    measured = [s for s in samples if s.get("kind") in LOCAL_KINDS and not s.get("warmup")]
    local = {"all": figures([s["accepted_to_readback_ms"] for s in measured if s.get("ok")])}
    for kind in LOCAL_KINDS:
        local[kind] = figures([s["accepted_to_readback_ms"] for s in measured if s["kind"] == kind and s.get("ok")])
        local[kind]["measure"] = next((s["measure"] for s in measured if s["kind"] == kind), None)
    local["client_round_trip_reference_only"] = figures([s["client_round_trip_ms"] for s in measured if s.get("ok")])
    problems = []
    if not done.get("ok"):
        problems.append(str(done.get("error")))
    failed = [s for s in measured if not s.get("ok")]
    if failed:
        problems.append(f"{len(failed)} operations were not read back ({failed[0].get('error') or failed[0].get('state')})")
    if local["all"]["n"] != local_count:
        problems.append(f"{local['all']['n']} of {local_count} operations measured")
    if local["all"]["p95_ms"] is not None and local["all"]["p95_ms"] > 100:
        problems.append(f"p95 {local['all']['p95_ms']} ms > 100")
    local_detail = "; ".join(problems) or (
        "accepted→readback p95 {} ms, p50 {}, max {} over {} (p95 by kind: workspace {} / focus {} / token {} ms)".format(
            local["all"]["p95_ms"], local["all"]["p50_ms"], local["all"]["max_ms"], local["all"]["n"],
            local["workspace_switch"]["p95_ms"], local["window_focus"]["p95_ms"], local["appearance_token"]["p95_ms"]))

    docks = [s for s in samples if s.get("kind") == "dock_switch" and not s.get("warmup")]
    dock = figures([s["prepared_to_committed_ms"] for s in docks
                    if s.get("ok") and s.get("prepared_to_committed_ms") is not None])
    dock_problems = []
    if not done.get("ok"):
        dock_problems.append(str(done.get("error")))
    not_committed = [s for s in docks if not s.get("ok")]
    if not_committed:
        first = not_committed[0]
        dock_problems.append(f"{len(not_committed)} switches did not commit or were not mounted "
                             f"({first.get('state')} {first.get('failure_key')}; Shell mounts {first.get('shell_mounts')}, "
                             f"wanted ditto.dock.{first.get('to')})")
    if dock["n"] != dock_count:
        dock_problems.append(f"{dock['n']} of {dock_count} switches have both stamps")
    if dock["p95_ms"] is not None and dock["p95_ms"] > 2000:
        dock_problems.append(f"p95 {dock['p95_ms']} ms > 2000")
    # Times Core ended the driver's change subscription (resync_required).
    dock["resubscribed"] = done.get("resubscribed")
    dock_detail = "; ".join(dock_problems) or (
        f"prepared→committed p95 {dock['p95_ms']} ms, p50 {dock['p50_ms']}, max {dock['max_ms']} (n={dock['n']})")

    print(json.dumps({
        "local": {"status": "fail" if problems else "pass", "detail": local_detail, "evidence": local},
        "dock": {"status": "fail" if dock_problems else "pass", "detail": dock_detail, "evidence": dock},
        "operations": len(measured) + len(docks),
    }))


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]))
