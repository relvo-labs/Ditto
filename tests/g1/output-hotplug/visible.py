#!/usr/bin/env python3
"""Which windows are visible, from Core's readback alone.

Reads the `dittoctl --json probe outputs`, `probe windows` and `probe
workspaces` records and prints one JSON object. Core reports window x/y
relative to the active workspace of the window's output (Wayfire's view
geometry), while output x/y are positions in the global layout, so the two
cannot be compared directly. A window therefore counts as visible when its
workspace is an active one and its centre lies inside its output. Its output
is known only when one output remains, or when the window's workspace id
names it; otherwise the window is listed as unmapped rather than guessed.
Minimized windows are skipped.
"""

import json
import sys


def result(path: str) -> dict:
    return json.load(open(path, encoding="utf-8")).get("result") or {}


def main() -> int:
    outputs = [o for o in result(sys.argv[1]).get("outputs", []) if o.get("enabled", True)]
    windows = result(sys.argv[2]).get("windows", [])
    active = {w["id"] for w in result(sys.argv[3]).get("workspaces", []) if w.get("active")}
    visible, hidden, unmapped = [], [], []
    for window in windows:
        if window.get("state") == "minimized":
            continue
        entry = {"app_id": window.get("app_id"), "id": window.get("id"),
                 "workspace_id": window.get("workspace_id"),
                 "local": [window.get("x"), window.get("y"), window.get("width"), window.get("height")]}
        if None in entry["local"] or len(outputs) != 1:
            unmapped.append(entry)
            continue
        output = outputs[0]
        cx = window["x"] + window["width"] / 2
        cy = window["y"] + window["height"] / 2
        inside = 0 <= cx < output["width"] and 0 <= cy < output["height"]
        entry["output"] = output["name"]
        (visible if inside and window.get("workspace_id") in active else hidden).append(entry)
    json.dump({"outputs": [o["name"] for o in outputs], "active_workspaces": sorted(active),
               "visible": visible, "hidden": hidden, "unmapped": unmapped,
               "all_visible": bool(visible) and not hidden and not unmapped},
              sys.stdout, ensure_ascii=False)
    print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
