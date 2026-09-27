#!/usr/bin/env python3
"""C-18: output hotplug events. Headless has no connector to unplug, so the
probe adds and removes a second headless output through Wayfire IPC and
records what a watching IPC client receives, what `list-outputs` reports, and
where a window on the removed output ends up. A physical unplug on the
reference machine is still required for EX1-13 ⑤; this is not that."""

import json
import sys
import time

import common
import wfipc

EVENTS = ["output-added", "output-removed", "output-layout-changed", "view-set-output",
          "output-wset-changed"]


def outputs(c: wfipc.Client) -> list[dict]:
    return [{k: o.get(k) for k in ("id", "name", "geometry", "wset-index")}
            for o in c.call("window-rules/list-outputs")]


def view(c: wfipc.Client, view_id: int) -> dict | None:
    for item in c.call("window-rules/list-views"):
        if item["id"] == view_id:
            return {k: item.get(k) for k in ("id", "app-id", "output-id", "output-name",
                                              "geometry", "wset-index", "tiled-edges")}
    return None


def main() -> int:
    c = wfipc.Client()
    watcher = wfipc.Client()
    steps = []
    ok = True
    try:
        steps.append({"step": "watch", "reply": watcher.call("window-rules/events/watch",
                                                              {"events": EVENTS})})
        window = common.open_window(c, "probe-hotplug")
        steps.append({"step": "baseline", "outputs": outputs(c), "view": view(c, window),
                      "events": watcher.events(0.3)})

        reply = c.call("wayfire/create-headless-output", {"width": 1280, "height": 720})
        added = (reply.get("output") or {})
        time.sleep(0.5)
        steps.append({"step": "create_headless_output", "reply": reply, "outputs": outputs(c),
                      "events": watcher.events(1.0)})

        moved = c.call("window-rules/configure-view", {"id": window, "output_id": added.get("id")})
        time.sleep(0.5)
        steps.append({"step": "move_view_to_new_output", "reply": moved, "view": view(c, window),
                      "events": watcher.events(0.5)})

        reply = c.call("wayfire/destroy-headless-output", {"output-id": added.get("id")})
        time.sleep(0.8)
        steps.append({"step": "destroy_headless_output", "reply": reply, "outputs": outputs(c),
                      "view": view(c, window), "events": watcher.events(1.0)})

        # The output configured at startup was not created over IPC.
        reply = c.call("wayfire/destroy-headless-output", {"output": "HEADLESS-1"})
        steps.append({"step": "destroy_startup_output_refused", "reply": reply})
    except Exception as error:
        steps.append({"step": "exception", "error": repr(error)})
        ok = False
    finally:
        common.stop_children()
    json.dump({"row": "C-18", "probe": "output hotplug events (headless, IPC-created output)",
               "steps": steps, "completed": ok}, sys.stdout, ensure_ascii=False, indent=1)
    sys.stdout.write("\n")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
