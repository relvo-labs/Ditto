#!/usr/bin/env python3
"""Judge one cleanup-stress group (EX1-04).

Pass when every count is the same at the first and the last snapshot, the
hostd PSS median of the second half grew at most 10% over the first half, and
the PSS series at the ten snapshot points has no monotonic trend
(Mann-Kendall, two-sided p >= 0.05). Prints one JSON line.
"""
import json
import math
import statistics
import sys


def mann_kendall(values):
    """Two-sided p-value of the Mann-Kendall trend test (with tie correction)."""
    n = len(values)
    s = sum((values[j] > values[i]) - (values[j] < values[i]) for i in range(n) for j in range(i + 1, n))
    ties = {}
    for value in values:
        ties[value] = ties.get(value, 0) + 1
    variance = (n * (n - 1) * (2 * n + 5) - sum(t * (t - 1) * (2 * t + 5) for t in ties.values())) / 18
    if variance <= 0:
        return s, 1.0
    z = (s - 1) / math.sqrt(variance) if s > 0 else (s + 1) / math.sqrt(variance) if s < 0 else 0.0
    p = math.erfc(abs(z) / math.sqrt(2))
    return s, p


def main():
    result = json.load(open(sys.argv[1], encoding="utf-8"))
    if not result.get("ok"):
        print(json.dumps({"status": "fail", "detail": result.get("error")}))
        return
    snapshots = result["snapshots"]
    first, last = snapshots[0]["counts"], snapshots[-1]["counts"]
    drift = {key: [first.get(key), last.get(key)] for key in sorted(set(first) | set(last)) if first.get(key) != last.get(key)}
    problems = []
    if drift:
        problems.append(f"counts differ first→last: {drift}")
    pss = [snapshot["hostd_pss_kib"] for snapshot in snapshots[1:]]
    evidence = {"counts_first": first, "counts_last": last, "hostd_pss_kib": [s["hostd_pss_kib"] for s in snapshots], "seconds": result.get("seconds")}
    if any(value is None for value in pss) or len(pss) < 4:
        problems.append("hostd PSS was not reported at every snapshot")
    else:
        half = len(pss) // 2
        growth = statistics.median(pss[half:]) / statistics.median(pss[:half]) - 1
        s, p = mann_kendall(pss)
        evidence.update({"pss_median_growth": round(growth, 4), "mann_kendall_s": s, "mann_kendall_p": round(p, 4)})
        if growth > 0.10:
            problems.append(f"hostd PSS median grew {growth:.1%} (> 10%)")
        if p < 0.05:
            problems.append(f"hostd PSS has a monotonic trend (Mann-Kendall S={s}, p={p:.3f})")
    pids = {snapshot["hostd_pid"] for snapshot in snapshots}
    if len(pids) != 1:
        problems.append(f"hostd restarted during the run (PIDs {sorted(p for p in pids if p)})")
    detail = "; ".join(problems) or (
        f"{result['cycles']} cycles after {result['warmup']} warm-up: counts identical first→last, "
        f"hostd PSS growth {evidence.get('pss_median_growth')}, Mann-Kendall p={evidence.get('mann_kendall_p')}")
    print(json.dumps({"status": "fail" if problems else "pass", "detail": detail, "evidence": evidence}, ensure_ascii=False))


main()
