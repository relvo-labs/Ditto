#!/usr/bin/env python3
"""Read the latest G1 VM result documents for the captured desktop screenshot."""
from datetime import datetime, timezone
import json
from pathlib import Path

print("DITTO  |  G1 DEVELOPMENT VM")
print(datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC"))
print("Exit evidence: physical reference machine only\n")
root = Path.home() / "funlab/Ditto/artifacts/g1"
summary_path = root.parent / "g1-vm-summary.jsonl"
summary = {}
if summary_path.exists():
    for line in summary_path.read_text(encoding="utf-8").splitlines():
        if line.strip():
            record = json.loads(line)
            summary[record["check"]] = record["status"]
for name in (
    "rust-workspace", "node-workspace",
    "contract-vectors", "preflight-negative", "rollback", "persistence-faults",
    "cordis-independent", "cleanup-stress", "latency", "rescue-no-node",
):
    if name in ("rust-workspace", "node-workspace"):
        print(f"{name:24} {summary.get(name, 'not run')}")
        continue
    paths = sorted(root.glob(f"{name}-*.json"))
    if not paths:
        print(f"{name:24} not run")
        continue
    result = json.loads(paths[-1].read_text(encoding="utf-8"))
    counts = {}
    for check in result.get("checks", []):
        status = check.get("status", "?")
        counts[status] = counts.get(status, 0) + 1
    print(f"{name:24} {result.get('status', '?'):16} {counts}")
