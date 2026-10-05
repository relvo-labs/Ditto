#!/usr/bin/env python3
"""C-15: can simple-tile be switched on and off while the session runs, and
what happens to windows that already exist? Every step reads geometry back."""

import json
import sys
import time

import common
import wfipc

WS = {"wset-index": 1, "workspace": {"x": 0, "y": 0}}
DEFAULT = {"x": 100, "y": 100, "width": 700, "height": 500}
FLOATING: dict[int, dict] = {}


def main() -> int:
    c = wfipc.Client()
    steps = []

    def record(name: str, **extra):
        step = {"step": name, "plugins_has_simple_tile": "simple-tile" in common.plugins(c),
                "views": common.toplevels(c)}
        try:
            step["layout"] = c.call("simple-tile/get-layout", WS)
        except Exception as error:  # the method may not exist when unloaded
            step["layout"] = {"exception": str(error)}
        step.update(extra)
        steps.append(step)
        return step

    try:
        a = common.open_window(c, "probe-a")
        b = common.open_window(c, "probe-b")
        record("baseline_floating")
        for view in common.toplevels(c):
            FLOATING[view["id"]] = view["geometry"]

        base = [p for p in common.plugins(c) if p != "simple-tile"]
        reply = common.set_plugins(c, base + ["simple-tile"])
        record("load_simple_tile", reply=reply)

        new = common.open_window(c, "probe-c")
        FLOATING[new] = DEFAULT
        record("new_view_after_load")

        # Put the pre-existing views into the tree explicitly.
        layout = {"vertical-split": [{"weight": 1.0, "view-id": v} for v in (a, b, new)]}
        reply = c.call("simple-tile/set-layout", dict(WS, layout=layout))
        time.sleep(0.5)
        record("set_layout_all_three", reply=reply)

        # Per-view toggle through the plugin's own key binding (<super> KEY_T).
        c.call("window-rules/focus-view", {"id": a})
        time.sleep(0.2)
        wfipc.press(c, "KEY_LEFTMETA", "KEY_T")
        time.sleep(0.5)
        record("toggle_key_on_a")

        # Remove b from the tree through set-layout: another per-view path.
        layout = {"vertical-split": [{"weight": 1.0, "view-id": new}]}
        reply = c.call("simple-tile/set-layout", dict(WS, layout=layout))
        time.sleep(0.5)
        record("set_layout_without_b", reply=reply)

        # A floating strategy while the plugin stays loaded: new views untiled.
        reply = c.call("wayfire/set-config-options", {"simple-tile/tile_by_default": "none"})
        time.sleep(0.3)
        common.open_window(c, "probe-d")
        record("tile_by_default_none_new_view", reply=reply)
        c.call("wayfire/set-config-options", {"simple-tile/tile_by_default": "all"})

        # Tile a and b again so unloading has several tiled views to release.
        layout = {"vertical-split": [{"weight": 1.0, "view-id": v} for v in (a, b, new)]}
        c.call("simple-tile/set-layout", dict(WS, layout=layout))
        time.sleep(0.5)
        record("retiled_before_unload")

        # Unloading while views are tiled: what does the plugin leave behind?
        reply = common.set_plugins(c, base)
        record("unload_simple_tile_while_tiled", reply=reply)

        # IPC restore without the plugin: configure-view writes pending state
        # directly (no saved-geometry restore), so the caller supplies it.
        replies = [c.call("window-rules/configure-view",
                          {"id": v, "tiled-edges": 0, "geometry": FLOATING[v]}) for v in (a, b, new)]
        time.sleep(0.5)
        record("configure_view_restore_after_unload", reply=replies)

        reply = common.set_plugins(c, base + ["simple-tile"])
        record("reload_simple_tile", reply=reply)
        common.open_window(c, "probe-e")
        record("new_view_after_reload")

        # The controlled-handoff path to floating with the plugin still loaded:
        # empty tree, then untile each former member with its floating geometry.
        tiled = [v["id"] for v in common.toplevels(c) if v["tiled_edges"]]
        reply = c.call("simple-tile/set-layout", dict(WS, layout={"vertical-split": []}))
        replies = [c.call("window-rules/configure-view",
                          {"id": v, "tiled-edges": 0, "geometry": FLOATING.get(v, DEFAULT)})
                   for v in tiled]
        time.sleep(0.5)
        record("empty_layout_and_untile", reply=[reply, *replies], untiled=tiled)
        alive = True
    except Exception as error:
        steps.append({"step": "exception", "error": repr(error)})
        alive = False
    finally:
        common.stop_children()

    json.dump({"row": "C-15", "probe": "simple-tile runtime switch", "steps": steps,
               "completed": alive}, sys.stdout, ensure_ascii=False, indent=1)
    sys.stdout.write("\n")
    return 0 if alive else 1


if __name__ == "__main__":
    sys.exit(main())
