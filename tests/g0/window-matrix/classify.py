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
    environments: set[str] = set()
    roles: set[str] = set()
    for line in open(sys.argv[1], encoding="utf-8"):
        cell = json.loads(line)
        environments.add(cell["environment"])
        if cell["role"] != "fixture-free":
            roles.add(cell["role"].removesuffix("-floating"))
        outcome = outcome_of(cell)
        counts[outcome] = counts.get(outcome, 0) + 1
        detail = "" if cell["ok"] else cell["error"]["message"]
        print(f'{outcome:12} {cell["capability"]:32} {cell["role"]:18} {detail}')
    print()
    if not counts:
        print("the matrix has no cells; an empty run is not a result")
        return 1
    print(" ".join(f"{name}={value}" for name, value in sorted(counts.items())))
    if counts.get("difference"):
        print("differences must be entered in docs/platform/compositor-capability-matrix.md")
    if environments == {"reference-machine"}:
        missing = {"browser", "terminal", "editor"} - roles
        if missing:
            print(f"reference run is missing frozen roles: {sorted(missing)}")
            return 1
        print("reference-machine matrix: all three frozen application roles are present")
    else:
        print("this run is development evidence; EX-01 is decided on the frozen reference machine")
    return 1 if counts.get("undecided") else 0


if __name__ == "__main__":
    raise SystemExit(main())
