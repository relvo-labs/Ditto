#!/usr/bin/env python3
"""Where the character is, from the Shell's report through Core.

Reads a `dittoctl --json probe outputs` record and a `dittoctl --json probe
call desktop.panels.list {}` record and prints one JSON object. The
character counts as visible when the Shell reports it shown, on a connected
output, with its whole surface inside that output. `expect_primary` (third
argument, optional) also requires that it follows the primary output, which
is what an unplugged named output must lead to.
"""

import json
import sys


def result(path: str) -> dict:
    return json.load(open(path, encoding="utf-8")).get("result") or {}


def main() -> int:
    outputs = {o["name"]: o for o in result(sys.argv[1]).get("outputs", []) if o.get("enabled", True)}
    panels = result(sys.argv[2])
    expect_primary = len(sys.argv) > 3 and sys.argv[3] == "expect_primary"
    placement = panels.get("avatar")
    verdict = {"shell_connected": panels.get("shell_connected"), "reported_at": panels.get("reported_at"),
               "placement": placement, "outputs": sorted(outputs)}
    problems = []
    if not placement:
        problems.append("the Shell reported no placement")
    else:
        output = outputs.get(placement.get("output") or "")
        if not placement.get("visible"):
            problems.append("the Shell reports the character hidden")
        if output is None:
            problems.append("the character is not on a connected output")
        else:
            x, y = placement["x"], placement["y"]
            right, bottom = x + placement["width"], y + placement["height"]
            if x < 0 or y < 0 or right > output["width"] or bottom > output["height"]:
                problems.append("the character's surface is outside its output")
        if expect_primary and not placement.get("follows_primary"):
            problems.append("the character does not follow the primary output")
    verdict["problems"] = problems
    verdict["visible"] = not problems
    json.dump(verdict, sys.stdout, ensure_ascii=False)
    print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
