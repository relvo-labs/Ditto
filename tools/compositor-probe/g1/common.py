"""Helpers shared by the G1 probe scripts: test windows and readback."""

import os
import subprocess
import time

import wfipc

CHILDREN: list[subprocess.Popen] = []


def toplevels(client: wfipc.Client) -> list[dict]:
    return [
        {
            "id": view["id"],
            "app_id": view.get("app-id"),
            "geometry": view.get("geometry"),
            "tiled_edges": view.get("tiled-edges"),
            "minimized": view.get("minimized"),
            "focused": view.get("activated"),
        }
        for view in client.call("window-rules/list-views")
        if view.get("role") == "toplevel" and view.get("mapped", True)
    ]


def view_id(client: wfipc.Client, app_id: str) -> int | None:
    for view in toplevels(client):
        if view["app_id"] == app_id:
            return view["id"]
    return None


def open_window(client: wfipc.Client, app_id: str, *command: str, timeout: float = 10.0) -> int:
    log = open(os.path.join(os.environ["XDG_RUNTIME_DIR"], f"{app_id}.log"), "w")
    CHILDREN.append(
        subprocess.Popen(["foot", f"--app-id={app_id}", *command], stdout=log, stderr=log)
    )
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        found = view_id(client, app_id)
        if found is not None:
            time.sleep(0.3)  # let the first configure settle before readback
            return found
        time.sleep(0.1)
    raise RuntimeError(f"window {app_id} did not appear")


def stop_children() -> None:
    for child in CHILDREN:
        child.kill()
    for child in CHILDREN:
        child.wait()


def plugins(client: wfipc.Client) -> list[str]:
    return client.call("wayfire/get-config-option", {"option": "core/plugins"})["value"].split()


def set_plugins(client: wfipc.Client, names: list[str]) -> dict:
    reply = client.call("wayfire/set-config-options", {"core/plugins": " ".join(names)})
    # reload_dynamic_plugins runs on the next idle of the compositor loop.
    time.sleep(0.5)
    return reply


def by_app(views: list[dict]) -> dict:
    return {view["app_id"]: view for view in views}
