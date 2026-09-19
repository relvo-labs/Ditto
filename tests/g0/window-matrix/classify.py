#!/usr/bin/env python3
"""Classify one window-matrix run. EX-01 asks every write cell to end either
verified by readback or explicitly unsupported; a difference is a real
compositor or application behaviour that belongs in the capability matrix."""

import json
import sys

READS = {
    "desktop.capabilities.list",
    "desktop.outputs.list",
    "desktop.workspaces.list",
    "desktop.workspaces.get",
    "desktop.windows.list",
    "desktop.windows.get",
}
DELIVERY = {"desktop.windows.close_request"}


def outcome_of(cell: dict) -> str:
    capability = cell["capability"]
    if cell["ok"] and cell["readback_verified"]:
        return "verified"
    if cell["ok"] and capability in DELIVERY:
        return "delivered"
    if cell["ok"] and capability in READS:
        return "read"
    if not cell["ok"]:
        name = cell["error"]["name"]
        if name == "unsupported":
            return "unsupported"
        if name == "conflict":
            return "difference"
        if name == "not_found" and capability in READS:
            return "read"
    return "undecided"


def main() -> int:
    counts: dict[str, int] = {}
    for line in open(sys.argv[1], encoding="utf-8"):
        cell = json.loads(line)
        outcome = outcome_of(cell)
        counts[outcome] = counts.get(outcome, 0) + 1
        detail = "" if cell["ok"] else cell["error"]["message"]
        print(f'{outcome:12} {cell["capability"]:32} {cell["role"]:18} {detail}')
    print()
    print(" ".join(f"{name}={value}" for name, value in sorted(counts.items())))
    if counts.get("difference"):
        print("differences must be entered in docs/platform/compositor-capability-matrix.md")
    print("this run is development evidence; EX-01 is decided on the frozen reference machine")
    return 1 if counts.get("undecided") else 0


if __name__ == "__main__":
    raise SystemExit(main())
