#!/usr/bin/env python3
"""Which windows are visible, from Core's readback alone.

Reads the `dittoctl --json probe outputs`, `probe windows` and `probe
workspaces` records and prints one JSON object. Core reports window x/y
relative to the window's output and to that output's current workspace
(Wayfire's view geometry), and names the output in `output`. A window counts
as visible when it is on a connected output, its workspace is an active one,
and its centre lies inside that output. A window that names no output is
judged against the only output when one remains, and listed as unmapped
otherwise rather than guessed. Minimized windows are skipped.
"""

import json
import sys


def result(path: str) -> dict:
    return json.load(open(path, encoding="utf-8")).get("result") or {}


def main() -> int:
    outputs = {o["name"]: o for o in result(sys.argv[1]).get("outputs", []) if o.get("enabled", True)}
    windows = result(sys.argv[2]).get("windows", [])
    active = {w["id"] for w in result(sys.argv[3]).get("workspaces", []) if w.get("active")}
    visible, hidden, unmapped = [], [], []
    for window in windows:
        if window.get("state") == "minimized":
            continue
        entry = {"app_id": window.get("app_id"), "id": window.get("id"),
                 "output": window.get("output"), "workspace_id": window.get("workspace_id"),
                 "local": [window.get("x"), window.get("y"), window.get("width"), window.get("height")]}
        name = window.get("output")
        if name is None and len(outputs) == 1:
            name = next(iter(outputs))
        if None in entry["local"] or name is None:
            unmapped.append(entry)
            continue
        output = outputs.get(name)
        if output is None:
            entry["why"] = "on an output that is not connected"
            hidden.append(entry)
            continue
        cx = window["x"] + window["width"] / 2
        cy = window["y"] + window["height"] / 2
        inside = 0 <= cx < output["width"] and 0 <= cy < output["height"]
        on_active = window.get("workspace_id") in active
        if inside and on_active:
            visible.append(entry)
        else:
            entry["why"] = "centre outside its output" if not inside else "on an inactive workspace"
            hidden.append(entry)
    json.dump({"outputs": sorted(outputs), "active_workspaces": sorted(active),
               "visible": visible, "hidden": hidden, "unmapped": unmapped,
               "all_visible": bool(visible) and not hidden and not unmapped},
              sys.stdout, ensure_ascii=False)
    print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
