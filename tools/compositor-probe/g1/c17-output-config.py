#!/usr/bin/env python3
"""C-17: change an output's scale and position while the session runs and
read it back from two independent places: Wayfire IPC (`list-outputs`, which
reports logical geometry but no scale) and the Wayland globals a client sees
(`wayland-info`: wl_output scale, xdg_output logical size and position), plus
the `output-layout-changed` IPC event."""

import json
import re
import shutil
import subprocess
import sys
import time

import wfipc


def wayland_view() -> dict:
    text = subprocess.run(["wayland-info"], capture_output=True, text=True, timeout=10).stdout
    wl_outputs, xdg_outputs = [], []
    for block in text.split("\ninterface: "):
        if block.startswith("'wl_output'"):
            found = re.search(r"x: (-?\d+), y: (-?\d+), scale: (\d+)", block)
            mode = re.search(r"width: (\d+) px, height: (\d+) px", block)
            wl_outputs.append({
                "name": (re.search(r"\tname: (\S+)", block) or [None, None])[1],
                "x": int(found[1]) if found else None, "y": int(found[2]) if found else None,
                "integer_scale": int(found[3]) if found else None,
                "mode": [int(mode[1]), int(mode[2])] if mode else None,
            })
        if block.startswith("'zxdg_output_manager_v1'"):
            for item in block.split("xdg_output_v1")[1:]:
                numbers = re.findall(r"logical_(x|y|width|height): (-?\d+)", item)
                xdg_outputs.append({"name": (re.search(r"name: '([^']+)'", item) or [None, None])[1],
                                    **{k: int(v) for k, v in numbers}})
    return {
        "zwlr_output_manager_v1_advertised": "'zwlr_output_manager_v1'" in text,
        "wp_fractional_scale_manager_v1_advertised": "'wp_fractional_scale_manager_v1'" in text,
        "wl_outputs": wl_outputs,
        "xdg_outputs": xdg_outputs,
    }


def snapshot(c: wfipc.Client) -> dict:
    return {
        "ipc_outputs": [{k: o.get(k) for k in ("id", "name", "geometry", "workarea")}
                        for o in c.call("window-rules/list-outputs")],
        "config_scale": c.call("wayfire/get-config-option", {"option": "output:HEADLESS-1/scale"}),
        "config_position": c.call("wayfire/get-config-option", {"option": "output:HEADLESS-1/position"}),
        "wayland": wayland_view(),
    }


def main() -> int:
    c = wfipc.Client()
    # output-layout-changed carries each output's scale, which list-outputs
    # does not; watch it on a connection of its own.
    watcher = wfipc.Client()
    watcher.call("window-rules/events/watch", {"events": ["output-layout-changed"]})
    steps = [{"step": "baseline", **snapshot(c)}]
    ok = True
    try:
        for name, options in (
            ("scale_1_25", {"output:HEADLESS-1/scale": "1.250000"}),
            ("position_100_50", {"output:HEADLESS-1/position": "100,50"}),
            ("restore", {"output:HEADLESS-1/scale": "1.000000", "output:HEADLESS-1/position": "0,0"}),
        ):
            reply = c.call("wayfire/set-config-options", options)
            time.sleep(0.8)
            steps.append({"step": name, "request": options, "reply": reply, **snapshot(c),
                          "events": watcher.events(0.5)})
    except Exception as error:
        steps.append({"step": "exception", "error": repr(error)})
        ok = False
    json.dump({"row": "C-17", "probe": "output scale and position change",
               "wlr_randr_installed": shutil.which("wlr-randr") is not None,
               "steps": steps, "completed": ok}, sys.stdout, ensure_ascii=False, indent=1)
    sys.stdout.write("\n")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
