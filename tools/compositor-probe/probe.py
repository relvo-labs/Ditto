#!/usr/bin/env python3
"""Compositor-neutral Wayland probe.

Layer one is the global inventory below: fast, complete, and unable to tell
support from advertisement. Layer two is `functional/run.sh`, which asks the
compositor to perform each operation and reads the result back; its output is
merged in with --functional. A row with no functional result gets no verdict.
"""

import argparse
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone


GLOBAL = re.compile(r"interface:\s*['\"](?P<interface>[^'\"]+)['\"],\s*version:\s*(?P<version>\d+),\s*name:\s*(?P<name>\d+)")


def parse_globals(output: str) -> list[dict[str, int | str]]:
    globals_ = [
        {
            "interface": match.group("interface"),
            "version": int(match.group("version")),
            "name": int(match.group("name")),
        }
        for match in GLOBAL.finditer(output)
    ]
    return sorted(globals_, key=lambda item: (str(item["interface"]), int(item["name"])))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--label", required=True, help="Opaque label for this compositor run")
    parser.add_argument(
        "--functional",
        type=argparse.FileType("r", encoding="utf-8"),
        help="Second-layer results produced by functional/run.sh inside a live session",
    )
    args = parser.parse_args()
    if not os.environ.get("XDG_RUNTIME_DIR"):
        parser.error("XDG_RUNTIME_DIR must point to a running Wayland session")
    result = subprocess.run(["wayland-info"], text=True, capture_output=True, check=False, timeout=15)
    if result.returncode:
        print(result.stderr.strip() or "wayland-info failed", file=sys.stderr)
        return 1
    functional = json.load(args.functional)["results"] if args.functional else []
    globals_ = parse_globals(result.stdout)
    if not globals_:
        print("wayland-info returned no parseable globals", file=sys.stderr)
        return 1
    record = {
        "schema_version": 1,
        "run_at_utc": datetime.now(timezone.utc).isoformat(),
        "compositor_label": args.label,
        "wayland_display": os.environ.get("WAYLAND_DISPLAY", "wayland-0"),
        "coverage": "globals_and_functional" if functional else "globals_only",
        "globals": globals_,
        "functional_results": functional,
        "limitation": "Global advertisement does not establish C-01..C-14 functional support. "
                      "Rows without a functional result keep no verdict; rows marked probed=false "
                      "were not exercised in this environment.",
    }
    print(json.dumps(record, ensure_ascii=False, sort_keys=True, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
